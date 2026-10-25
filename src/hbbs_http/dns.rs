//! Bounded system DNS: cancelling the async waiter must not release admission
//! for an OS getaddrinfo call that is still running. No fallback resolver/queue.

use camellia_remote_protocol::tokio;
use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use std::{
    io,
    net::{SocketAddr, ToSocketAddrs},
    sync::{Arc, LazyLock},
};

const MAX_DNS_WORKERS: usize = 8;
const MAX_ADDRESSES: usize = 64;
static RESOLVER: LazyLock<Arc<BoundedResolver>> =
    LazyLock::new(|| Arc::new(BoundedResolver::new(MAX_DNS_WORKERS)));

pub(super) fn shared() -> Arc<BoundedResolver> {
    RESOLVER.clone()
}

pub(super) struct BoundedResolver {
    permits: Arc<tokio::sync::Semaphore>,
}
impl BoundedResolver {
    fn new(limit: usize) -> Self {
        Self {
            permits: Arc::new(tokio::sync::Semaphore::new(limit)),
        }
    }

    fn lookup<F>(&self, operation: F) -> Resolving
    where
        F: FnOnce() -> io::Result<Vec<SocketAddr>> + Send + 'static,
    {
        let permits = self.permits.clone();
        Box::pin(async move {
            let permit = permits
                .try_acquire_owned()
                .map_err(|_| failure("dns_capacity_exhausted"))?;
            if tokio::runtime::Handle::try_current().is_err() {
                return Err(failure("dns_runtime_unavailable"));
            }
            // The closure, not the async JoinHandle, owns the permit. Dropping
            // the waiter never admits more OS work while this call is blocked.
            let result = tokio::task::spawn_blocking(move || {
                let _permit = permit;
                operation()
            })
            .await
            .map_err(|_| failure("dns_worker_failed"))?
            .map_err(|_| failure("dns_failed"))?;
            if result.is_empty() {
                return Err(failure("dns_no_addresses"));
            }
            Ok(Box::new(result.into_iter().take(MAX_ADDRESSES)) as Addrs)
        })
    }
}

type DnsError = Box<dyn std::error::Error + Send + Sync>;
fn failure(code: &'static str) -> DnsError {
    Box::new(io::Error::other(code))
}

impl Resolve for BoundedResolver {
    fn resolve(&self, name: Name) -> Resolving {
        if name.as_str().is_empty() || name.as_str().len() > 253 {
            return Box::pin(async { Err(failure("dns_invalid_name")) });
        }
        let name = name.as_str().to_owned();
        self.lookup(move || {
            (name.as_str(), 0)
                .to_socket_addrs()
                .map(|addresses| addresses.take(MAX_ADDRESSES).collect())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        sync::{
            atomic::{AtomicUsize, Ordering},
            Condvar, Mutex,
        },
        time::Duration,
    };

    #[derive(Default)]
    struct Gate {
        released: Mutex<bool>,
        wake: Condvar,
    }
    impl Gate {
        fn wait(&self) {
            let mut released = self.released.lock().unwrap();
            while !*released {
                released = self.wake.wait(released).unwrap();
            }
        }
        fn release(&self) {
            *self.released.lock().unwrap() = true;
            self.wake.notify_all();
        }
    }
    struct Release(Arc<Gate>);
    impl Drop for Release {
        fn drop(&mut self) {
            self.0.release();
        }
    }
    fn address() -> SocketAddr {
        "127.0.0.1:0".parse().unwrap()
    }

    #[tokio::test(flavor = "current_thread")]
    async fn cancelled_waiters_cannot_create_unbounded_os_workers_or_block_heartbeat() {
        let resolver = BoundedResolver::new(2);
        let gate = Arc::new(Gate::default());
        let _release = Release(gate.clone()); // Also unblocks OS workers on assertion failure.
        let calls = Arc::new(AtomicUsize::new(0));
        let mut tasks = Vec::new();
        for _ in 0..2 {
            let gate = gate.clone();
            let calls = calls.clone();
            let (ready, entered) = tokio::sync::oneshot::channel();
            let future = resolver.lookup(move || {
                calls.fetch_add(1, Ordering::AcqRel);
                ready.send(()).unwrap();
                gate.wait();
                Ok(vec![address()])
            });
            tasks.push(tokio::spawn(future));
            tokio::time::timeout(Duration::from_secs(2), entered)
                .await
                .unwrap()
                .unwrap();
        }
        for task in tasks {
            task.abort();
        }
        tokio::task::yield_now().await;
        for _ in 0..1000 {
            let result = resolver
                .lookup(|| panic!("No third OS resolver may start"))
                .await;
            assert_eq!(result.err().unwrap().to_string(), "dns_capacity_exhausted");
        }
        assert_eq!(calls.load(Ordering::Acquire), 2);
        tokio::time::timeout(
            Duration::from_millis(100),
            tokio::time::sleep(Duration::from_millis(1)),
        )
        .await
        .unwrap();
        gate.release();
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if resolver.permits.available_permits() == 2 {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let addresses = resolver
            .lookup(|| Ok(vec![address()]))
            .await
            .unwrap()
            .collect::<Vec<_>>();
        assert_eq!(addresses, [address()]);
    }

    #[tokio::test]
    async fn failed_empty_and_oversized_results_have_bounded_static_outcomes_and_release_admission()
    {
        let resolver = BoundedResolver::new(1);
        let error = resolver
            .lookup(|| Err(io::Error::other("PRIVATE-DNS-NAME")))
            .await
            .err()
            .unwrap();
        assert_eq!(error.to_string(), "dns_failed");
        assert_eq!(
            resolver
                .lookup(|| Ok(vec![]))
                .await
                .err()
                .unwrap()
                .to_string(),
            "dns_no_addresses"
        );
        let addresses = resolver
            .lookup(|| Ok(vec![address(); 1000]))
            .await
            .unwrap()
            .collect::<Vec<_>>();
        assert_eq!(addresses.len(), MAX_ADDRESSES);
        assert_eq!(resolver.permits.available_permits(), 1);
    }

    #[tokio::test]
    async fn numeric_loopback_uses_system_resolver_without_external_dns() {
        let resolver = BoundedResolver::new(1);
        let addresses = resolver
            .resolve("127.0.0.1".parse().unwrap())
            .await
            .unwrap()
            .collect::<Vec<_>>();
        assert!(!addresses.is_empty());
        assert!(addresses
            .iter()
            .all(|address| address.ip().is_loopback() && address.port() == 0));
    }
}
