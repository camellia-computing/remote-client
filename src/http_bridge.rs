//! Bounded, consuming HTTP request identities on the existing bridge runtime.
//! No per-request OS thread/runtime, fallback replay, plaintext diagnostic body,
//! or URL-keyed response ownership. A dropped/expired caller cancels its worker.

use camellia_remote_protocol::{
    base64::{engine::general_purpose::STANDARD as BASE64, Engine as _},
    config::{Config, Socks5Server},
    futures::FutureExt,
    rand::RngCore,
    rendezvous_proto::HeaderEntry,
    tokio::{self, sync::Semaphore},
    tokio_util::sync::CancellationToken,
};
use reqwest::{
    header::{HeaderMap, HeaderName, HeaderValue},
    Client, Method,
};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    future::Future,
    sync::{Arc, LazyLock, Mutex},
    time::{Duration, Instant},
};

const MAX_ACTIVE: usize = 8;
const MAX_ENTRIES: usize = 32;
const MAX_BODY: usize = 1024 * 1024;
const MAX_HEADERS: usize = 16 * 1024;
const MAX_RESULT_BYTES: usize = 8 * 1024 * 1024;
const REQUEST_BUDGET: Duration = Duration::from_secs(12);
const RESULT_TTL: Duration = Duration::from_secs(30);

type Failure = &'static str;

struct Request {
    url: url::Url,
    method: Method,
    body: String,
    headers: HeaderMap,
}

impl Request {
    fn parse(
        url: String,
        method: String,
        body: Option<String>,
        header: String,
    ) -> Result<Self, Failure> {
        let body = body.unwrap_or_default();
        if url.len() > 2048
            || method.len() > 6
            || body.len() > MAX_BODY
            || header.len() > MAX_HEADERS
        {
            return Err("request_too_large");
        }
        let url = url::Url::parse(&url).map_err(|_| "invalid_request")?;
        if !matches!(url.scheme(), "http" | "https")
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
        {
            return Err("invalid_request");
        }
        let method = match method.to_ascii_uppercase().as_str() {
            "GET" => Method::GET,
            "POST" => Method::POST,
            "PUT" => Method::PUT,
            "DELETE" => Method::DELETE,
            _ => return Err("invalid_request"),
        };
        let values: HashMap<String, String> =
            serde_json::from_str(&header).map_err(|_| "invalid_headers")?;
        if values.len() > 64 {
            return Err("invalid_headers");
        }
        let mut headers = HeaderMap::new();
        for (name, value) in values {
            let name = HeaderName::from_bytes(name.as_bytes()).map_err(|_| "invalid_headers")?;
            let value = HeaderValue::from_str(&value).map_err(|_| "invalid_headers")?;
            if headers.contains_key(&name)
                || matches!(
                    name.as_str(),
                    "host"
                        | "transfer-encoding"
                        | "connection"
                        | "proxy-authorization"
                        | "proxy-connection"
                )
            {
                return Err("invalid_headers");
            }
            if name == reqwest::header::CONTENT_LENGTH {
                if value
                    .to_str()
                    .ok()
                    .and_then(|value| value.parse::<usize>().ok())
                    != Some(body.len())
                {
                    return Err("invalid_headers");
                }
            } else {
                headers.insert(name, value);
            }
        }
        Ok(Self {
            url,
            method,
            body,
            headers,
        })
    }
}

fn envelope(id: &str, state: &str) -> Value {
    json!({"http_bridge_version": 1, "request_id": id, "state": state})
}

fn failed(id: &str, code: Failure) -> Value {
    let mut value = envelope(id, "failed");
    value["code"] = json!(code);
    value
}

fn response_value(status: u16, headers: HeaderMap, bytes: &[u8]) -> Result<Value, Failure> {
    if bytes.len() > MAX_BODY {
        return Err("response_too_large");
    }
    let mut result = serde_json::Map::new();
    let mut size = 0;
    if headers.len() > 64 {
        return Err("invalid_response_headers");
    }
    for (name, value) in &headers {
        let value = value.to_str().map_err(|_| "invalid_response_headers")?;
        size += name.as_str().len() + value.len();
        if size > MAX_HEADERS {
            return Err("invalid_response_headers");
        }
        if let Some(previous) = result.get(name.as_str()) {
            if matches!(
                name.as_str(),
                "content-type" | "content-length" | "location"
            ) {
                return Err("invalid_response_headers");
            }
            let joined = format!(
                "{}, {value}",
                previous.as_str().ok_or("invalid_response_headers")?
            );
            result.insert(name.to_string(), json!(joined));
        } else {
            result.insert(name.to_string(), json!(value));
        }
    }
    Ok(json!({"status_code": status, "headers": result, "body_base64": BASE64.encode(bytes)}))
}

enum RequestRoute {
    Http(Client),
    RawTcp(crate::common::RawTcpContext),
}

async fn request_once(request: Request, route: RequestRoute) -> Result<Value, Failure> {
    let client = match route {
        RequestRoute::Http(client) => client,
        RequestRoute::RawTcp(context) => {
            let headers = request
                .headers
                .iter()
                .map(|(name, value)| {
                    Ok(HeaderEntry {
                        name: name.to_string(),
                        value: value.to_str().map_err(|_| "invalid_headers")?.to_owned(),
                        ..Default::default()
                    })
                })
                .collect::<Result<Vec<_>, Failure>>()?;
            let response = crate::common::bridge_raw_tcp_request(
                context,
                request.url.as_str(),
                request.method.as_str(),
                request.body.as_bytes(),
                headers,
            )
            .await
            .map_err(|_| "transport_failed")?;
            if !response.error.is_empty() {
                return Err("transport_failed");
            }
            let status = u16::try_from(response.status).map_err(|_| "invalid_response")?;
            if (300..400).contains(&status) {
                return Err("redirect_rejected");
            }
            if !(100..600).contains(&status) {
                return Err("invalid_response");
            }
            if response.body.len() > MAX_BODY {
                return Err("response_too_large");
            }
            if response.headers.len() > 64 {
                return Err("invalid_response_headers");
            }
            let mut headers = HeaderMap::new();
            for entry in response.headers {
                let name = HeaderName::from_bytes(entry.name.as_bytes())
                    .map_err(|_| "invalid_response_headers")?;
                headers.append(
                    name,
                    HeaderValue::from_str(&entry.value).map_err(|_| "invalid_response_headers")?,
                );
            }
            return response_value(status, headers, &response.body);
        }
    };
    let mut response = client
        .request(request.method, request.url)
        .headers(request.headers)
        .body(request.body)
        .send()
        .await
        .map_err(|_| "transport_failed")?;
    if response.status().is_redirection() {
        return Err("redirect_rejected");
    }
    if response
        .content_length()
        .is_some_and(|size| size > MAX_BODY as u64)
    {
        return Err("response_too_large");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| "transport_failed")? {
        if chunk.len() > MAX_BODY - bytes.len() {
            return Err("response_too_large");
        }
        bytes.extend_from_slice(&chunk);
    }
    response_value(
        response.status().as_u16(),
        response.headers().clone(),
        &bytes,
    )
}

struct Entry {
    cancel: CancellationToken,
    expires: Instant,
    result: Option<String>,
}

/// Both active I/O and retained (unconsumed) results have hard limits. Cancellation
/// removes ownership immediately but the permit stays with the actual worker.
struct Broker {
    entries: Mutex<HashMap<String, Entry>>,
    permits: Arc<Semaphore>,
}

impl Broker {
    fn new() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
            permits: Arc::new(Semaphore::new(MAX_ACTIVE)),
        }
    }

    fn prune(&self, now: Instant) {
        let cancelled = if let Ok(mut entries) = self.entries.lock() {
            let expired: Vec<_> = entries
                .iter()
                .filter(|(_, entry)| entry.expires <= now)
                .map(|(id, _)| id.clone())
                .collect();
            expired
                .into_iter()
                .filter_map(|id| entries.remove(&id))
                .map(|entry| entry.cancel)
                .collect::<Vec<_>>()
        } else {
            return;
        };
        for token in cancelled {
            token.cancel();
        }
    }

    fn start<F>(self: &Arc<Self>, future: F) -> Value
    where
        F: Future<Output = Result<Value, Failure>> + Send + 'static,
    {
        if tokio::runtime::Handle::try_current().is_err() {
            return failed("", "runtime_unavailable");
        }
        self.prune(Instant::now());
        let permit = match self.permits.clone().try_acquire_owned() {
            Ok(permit) => permit,
            Err(_) => return failed("", "capacity_exhausted"),
        };
        let mut random = [0; 16];
        if camellia_remote_protocol::rand::rngs::OsRng
            .try_fill_bytes(&mut random)
            .is_err()
        {
            return failed("", "runtime_unavailable");
        }
        let id = uuid::Builder::from_random_bytes(random)
            .into_uuid()
            .to_string();
        let token = CancellationToken::new();
        {
            let mut entries = match self.entries.lock() {
                Ok(entries) => entries,
                Err(_) => return failed("", "runtime_unavailable"),
            };
            if entries.len() >= MAX_ENTRIES {
                return failed("", "capacity_exhausted");
            }
            if entries.contains_key(&id) {
                return failed("", "runtime_unavailable");
            }
            entries.insert(
                id.clone(),
                Entry {
                    cancel: token.clone(),
                    expires: Instant::now() + REQUEST_BUDGET,
                    result: None,
                },
            );
        }
        let owner = Arc::downgrade(self);
        let request_id = id.clone();
        tokio::spawn(async move {
            let _permit = permit;
            let outcome = tokio::select! {
                biased;
                _ = token.cancelled() => return,
                result = tokio::time::timeout(REQUEST_BUDGET, std::panic::AssertUnwindSafe(future).catch_unwind()) => match result {
                    Ok(Ok(result)) => result, Ok(Err(_)) => Err("worker_failed"), Err(_) => Err("deadline"),
                },
            };
            if let Some(owner) = owner.upgrade() {
                owner.complete(&request_id, outcome);
            }
        });
        envelope(&id, "accepted")
    }

    fn complete(&self, id: &str, outcome: Result<Value, Failure>) {
        let value = match outcome {
            Ok(response) => {
                let mut value = envelope(id, "complete");
                value["response"] = response;
                value
            }
            Err(code) => failed(id, code),
        };
        let text = value.to_string();
        if let Ok(mut entries) = self.entries.lock() {
            let total: usize = entries
                .values()
                .filter_map(|entry| entry.result.as_ref())
                .map(String::len)
                .sum();
            if let Some(entry) = entries.get_mut(id) {
                entry.result = Some(
                    if total + text.len() > MAX_RESULT_BYTES - MAX_ENTRIES * 512 {
                        failed(id, "result_capacity_exhausted").to_string()
                    } else {
                        text
                    },
                );
                entry.expires = Instant::now() + RESULT_TTL;
            }
        }
    }

    fn poll(&self, id: &str) -> String {
        self.prune(Instant::now());
        if let Ok(mut entries) = self.entries.lock() {
            if let Some(entry) = entries.get(id) {
                if entry.result.is_none() {
                    return envelope(id, "pending").to_string();
                }
            }
            if let Some(entry) = entries.remove(id) {
                if let Some(result) = entry.result {
                    return result;
                }
            }
        }
        failed(id, "request_missing").to_string()
    }

    fn cancel(&self, id: &str) {
        let removed = self
            .entries
            .lock()
            .ok()
            .and_then(|mut entries| entries.remove(id));
        if let Some(entry) = removed {
            entry.cancel.cancel();
        }
    }
}

static BROKER: LazyLock<Arc<Broker>> = LazyLock::new(|| Arc::new(Broker::new()));
static SWEEPER: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
type CachedClient = Option<(Option<Socks5Server>, String, Client)>;
static CLIENT: Mutex<CachedClient> = Mutex::new(None);

fn client_for(conf: &Option<Socks5Server>, origin: &str) -> Result<Client, Failure> {
    let mut cached = CLIENT.lock().map_err(|_| "runtime_unavailable")?;
    if let Some((previous, previous_origin, client)) = cached.as_ref() {
        if previous == conf && previous_origin == origin {
            return Ok(client.clone());
        }
    }
    // Drop old policy before constructing the new one. An invalid policy cannot
    // keep serving requests with a cached direct/previous proxy configuration.
    *cached = None;
    let client = crate::hbbs_http::create_http_client_async_for_configuration(conf.as_ref())
        .map_err(|_| "client_configuration_invalid")?;
    *cached = Some((conf.clone(), origin.to_owned(), client.clone()));
    Ok(client)
}

/// Called by an async generated FFI method, therefore on the existing shared
/// FRB Tokio runtime. This module never constructs or blocks on another runtime.
pub(crate) async fn start(
    url: String,
    method: String,
    body: Option<String>,
    header: String,
) -> String {
    let request = match Request::parse(url, method, body, header) {
        Ok(request) => request,
        Err(code) => return failed("", code).to_string(),
    };
    let conf = Config::get_socks();
    let raw_tcp = conf.is_none() && crate::common::bridge_raw_tcp_target(request.url.as_str());
    let raw_context = if raw_tcp {
        Some(crate::common::capture_raw_tcp_context().await)
    } else {
        None
    };
    if !SWEEPER.swap(true, std::sync::atomic::Ordering::AcqRel) {
        let owner = Arc::downgrade(&BROKER);
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(1));
            loop {
                interval.tick().await;
                let Some(owner) = owner.upgrade() else {
                    break;
                };
                owner.prune(Instant::now());
            }
        });
    }
    BROKER
        .start(async move {
            // Construct clients only after admission; raw TCP needs no HTTP
            // client. The cache retains one origin/proxy plus active handles.
            let route = match raw_context {
                Some(context) => RequestRoute::RawTcp(context),
                None => RequestRoute::Http(client_for(
                    &conf,
                    &request.url.origin().ascii_serialization(),
                )?),
            };
            request_once(request, route).await
        })
        .to_string()
}

fn valid_id(id: &str) -> bool {
    if id.len() != 36 {
        return false;
    }
    uuid::Uuid::parse_str(id).is_ok_and(|parsed| {
        parsed.get_version_num() == 4
            && parsed.get_variant() == uuid::Variant::RFC4122
            && parsed.to_string() == id
    })
}
pub(crate) fn poll(id: String) -> String {
    if !valid_id(&id) {
        return failed("", "invalid_request_id").to_string();
    }
    BROKER.poll(&id)
}
pub(crate) fn cancel(id: String) {
    if valid_id(&id) {
        BROKER.cancel(&id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    fn id(value: &Value) -> String {
        value["request_id"].as_str().unwrap().to_owned()
    }
    fn state(text: &str) -> Value {
        serde_json::from_str(text).unwrap()
    }
    async fn settle() {
        for _ in 0..4 {
            tokio::task::yield_now().await;
        }
    }

    #[tokio::test]
    async fn independent_identities_complete_out_of_order_and_consume_once() {
        let broker = Arc::new(Broker::new());
        let (first, first_rx) = tokio::sync::oneshot::channel::<Value>();
        let (second, second_rx) = tokio::sync::oneshot::channel::<Value>();
        let a = id(&broker.start(async { Ok(first_rx.await.unwrap()) }));
        let b = id(&broker.start(async { Ok(second_rx.await.unwrap()) }));
        assert_ne!(a, b);
        second.send(json!({"body": "second"})).unwrap();
        settle().await;
        assert_eq!(state(&broker.poll(&b))["response"]["body"], "second");
        assert_eq!(state(&broker.poll(&a))["state"], "pending");
        assert_eq!(state(&broker.poll(&b))["code"], "request_missing");
        first.send(json!({"body": "first"})).unwrap();
        settle().await;
        assert_eq!(state(&broker.poll(&a))["response"]["body"], "first");
        assert!(broker.entries.lock().unwrap().is_empty());
    }

    struct Dropped(Arc<AtomicBool>);
    impl Drop for Dropped {
        fn drop(&mut self) {
            self.0.store(true, Ordering::Release);
        }
    }

    #[tokio::test]
    async fn cancellation_drops_io_before_releasing_permit_and_late_result_cannot_reappear() {
        let broker = Arc::new(Broker::new());
        let dropped = Arc::new(AtomicBool::new(false));
        let guard = Dropped(dropped.clone());
        let request_id = id(&broker.start(async move {
            let _guard = guard;
            std::future::pending::<Result<Value, Failure>>().await
        }));
        settle().await;
        assert_eq!(broker.permits.available_permits(), MAX_ACTIVE - 1);
        broker.cancel(&request_id);
        settle().await;
        assert!(dropped.load(Ordering::Acquire));
        assert_eq!(broker.permits.available_permits(), MAX_ACTIVE);
        broker.complete(&request_id, Ok(json!("late")));
        assert_eq!(state(&broker.poll(&request_id))["code"], "request_missing");
    }

    #[tokio::test]
    async fn active_admission_is_fail_fast_and_never_exceeds_eight_workers() {
        let broker = Arc::new(Broker::new());
        let mut requests = Vec::new();
        for _ in 0..MAX_ACTIVE {
            requests.push(id(
                &broker.start(std::future::pending::<Result<Value, Failure>>())
            ));
        }
        assert_eq!(
            broker.start(async { Ok(json!(0)) })["code"],
            "capacity_exhausted"
        );
        assert_eq!(broker.entries.lock().unwrap().len(), MAX_ACTIVE);
        for request in requests {
            broker.cancel(&request);
        }
        settle().await;
        assert_eq!(broker.permits.available_permits(), MAX_ACTIVE);
    }

    #[tokio::test]
    async fn retained_results_are_bounded_without_evicting_another_callers_response() {
        let broker = Arc::new(Broker::new());
        let mut ids = Vec::new();
        for i in 0..MAX_ENTRIES {
            ids.push(id(&broker.start(async move { Ok(json!(i)) })));
            settle().await;
        }
        assert_eq!(
            broker.start(async { Ok(json!(0)) })["code"],
            "capacity_exhausted"
        );
        assert_eq!(state(&broker.poll(&ids[0]))["response"], 0);
        assert_eq!(
            state(&broker.poll(&ids[MAX_ENTRIES - 1]))["response"],
            MAX_ENTRIES - 1
        );
        broker.prune(Instant::now() + RESULT_TTL + Duration::from_secs(1));
        assert!(broker.entries.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn expiry_cancels_actual_future_not_just_its_result_slot() {
        let broker = Arc::new(Broker::new());
        let dropped = Arc::new(AtomicBool::new(false));
        let guard = Dropped(dropped.clone());
        let request_id = id(&broker.start(async move {
            let _guard = guard;
            std::future::pending::<Result<Value, Failure>>().await
        }));
        settle().await;
        broker.prune(Instant::now() + REQUEST_BUDGET + Duration::from_secs(1));
        settle().await;
        assert!(dropped.load(Ordering::Acquire));
        assert_eq!(state(&broker.poll(&request_id))["code"], "request_missing");
        assert_eq!(broker.permits.available_permits(), MAX_ACTIVE);
    }

    #[tokio::test]
    async fn thousand_unique_requests_do_not_leave_consumed_results_or_workers() {
        let broker = Arc::new(Broker::new());
        let mut ids = std::collections::HashSet::new();
        for i in 0..1000 {
            let request_id = id(&broker.start(async move { Ok(json!(i)) }));
            assert!(ids.insert(request_id.clone()));
            settle().await;
            assert_eq!(state(&broker.poll(&request_id))["response"], i);
        }
        assert!(broker.entries.lock().unwrap().is_empty());
        assert_eq!(broker.permits.available_permits(), MAX_ACTIVE);
    }

    #[tokio::test]
    async fn completed_result_memory_has_a_hard_byte_budget() {
        let broker = Arc::new(Broker::new());
        let mut ids = Vec::new();
        for _ in 0..16 {
            ids.push(id(&broker.start(async { Ok(json!("x".repeat(MAX_BODY))) })));
            settle().await;
        }
        let total: usize = broker
            .entries
            .lock()
            .unwrap()
            .values()
            .filter_map(|entry| entry.result.as_ref())
            .map(String::len)
            .sum();
        assert!(total <= MAX_RESULT_BYTES);
        assert_eq!(state(&broker.poll(&ids[0]))["state"], "complete");
        assert_eq!(
            state(&broker.poll(ids.last().unwrap()))["code"],
            "result_capacity_exhausted"
        );
    }

    #[test]
    fn request_schema_rejects_injected_headers_oversize_and_invalid_urls() {
        for headers in ["{", "[]", "{\"Authorization\":null}"] {
            assert!(Request::parse(
                "https://example.test/".to_owned(),
                "GET".to_owned(),
                None,
                headers.to_owned()
            )
            .is_err());
        }
        let request = Request::parse(
            "https://example.test/".to_owned(),
            "GET".to_owned(),
            None,
            r#"{"Content-Type":"text/plain","Authorization":"Bearer token"}"#.to_owned(),
        )
        .unwrap();
        assert_eq!(request.headers[reqwest::header::CONTENT_TYPE], "text/plain");
        let request = Request::parse(
            "https://example.test/".to_owned(),
            "GET".to_owned(),
            None,
            r#"{"Authorization":"Bearer token"}"#.to_owned(),
        )
        .unwrap();
        assert!(!request.headers.contains_key(reqwest::header::CONTENT_TYPE));
        for (url, method, body, headers) in [
            ("https://user:secret@example.test/", "GET", "", "{}"),
            ("file:///etc/private", "GET", "", "{}"),
            ("https://example.test/", "PATCH", "", "{}"),
            ("https://example.test/", "GET", "", "{\"X\":\"a\\r\\nb\"}"),
            (
                "https://example.test/",
                "POST",
                "",
                "{\"Host\":\"other.test\"}",
            ),
            (
                "https://example.test/",
                "POST",
                "",
                "{\"Content-Length\":\"4\"}",
            ),
        ] {
            assert!(Request::parse(
                url.to_owned(),
                method.to_owned(),
                Some(body.to_owned()),
                headers.to_owned()
            )
            .is_err());
        }
        assert!(Request::parse(
            "https://example.test/".to_owned(),
            "POST".to_owned(),
            Some("x".repeat(MAX_BODY + 1)),
            "{}".to_owned()
        )
        .is_err());
        assert!(Request::parse(
            "https://example.test/".to_owned(),
            "POST".to_owned(),
            None,
            "{\"Content-Length\":\"0\"}".to_owned()
        )
        .is_ok());
        assert!(!valid_id("../../../private"));
        assert!(!valid_id("03440000-0000-1000-8000-000000000001"));
    }

    #[tokio::test]
    async fn redirects_never_reach_the_second_endpoint() {
        let target = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/original", origin.local_addr().unwrap());
        let location = format!("http://{}/must-not-send", target.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (mut connection, _) = origin.accept().await.unwrap();
            let mut request = [0; 4096];
            connection.read(&mut request).await.unwrap();
            connection.write_all(format!("HTTP/1.1 307 Temporary Redirect\r\nLocation: {location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
        });
        let client = crate::hbbs_http::create_http_client_async_for_configuration(None).unwrap();
        let request = Request::parse(
            url,
            "POST".to_owned(),
            Some("one-intent".to_owned()),
            "{}".to_owned(),
        )
        .unwrap();
        let result = tokio::time::timeout(
            Duration::from_secs(2),
            request_once(request, RequestRoute::Http(client)),
        )
        .await
        .unwrap();
        assert_eq!(result.unwrap_err(), "redirect_rejected");
        server.await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(50), target.accept())
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn cancelling_a_real_stalled_http_request_closes_its_socket() {
        let origin = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/stalled", origin.local_addr().unwrap());
        let (ready, received) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(async move {
            let (mut connection, _) = origin.accept().await.unwrap();
            let mut request = [0; 4096];
            assert!(connection.read(&mut request).await.unwrap() > 0);
            ready.send(()).unwrap();
            tokio::time::timeout(Duration::from_secs(2), connection.read(&mut request))
                .await
                .unwrap()
                .unwrap()
        });
        let client = crate::hbbs_http::create_http_client_async_for_configuration(None).unwrap();
        let request = Request::parse(url, "GET".to_owned(), None, "{}".to_owned()).unwrap();
        let broker = Arc::new(Broker::new());
        let request_id = id(&broker.start(request_once(request, RequestRoute::Http(client))));
        tokio::time::timeout(Duration::from_secs(2), received)
            .await
            .unwrap()
            .unwrap();
        broker.cancel(&request_id);
        assert_eq!(server.await.unwrap(), 0);
        settle().await;
        assert_eq!(broker.permits.available_permits(), MAX_ACTIVE);
    }
}
