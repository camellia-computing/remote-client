use camellia_remote_protocol::{
    anyhow::anyhow,
    config::{Config, Socks5Server},
    tls::TlsType,
    ResultType,
};
use reqwest::{blocking::Client as SyncClient, Client as AsyncClient};
use std::time::Duration;

/// Resolve policy only: DNS/connect happen in reqwest's bounded request, not
/// synchronously in Protocol's TCP proxy parser. Never expose configuration in
/// errors, and never substitute a direct client after an explicit proxy fails.
fn configured_proxy(conf: &Socks5Server) -> ResultType<reqwest::Proxy> {
    if conf.proxy.len() > 4096
        || conf.proxy.trim() != conf.proxy
        || conf
            .proxy
            .chars()
            .any(|ch| ch.is_control() || ch.is_whitespace())
        || conf.username.len() > 1024
        || conf.password.len() > 1024
        || conf
            .username
            .chars()
            .chain(conf.password.chars())
            .any(char::is_control)
    {
        return Err(anyhow!("http_proxy_configuration_invalid"));
    }
    // The settings UI explicitly supports host:port as a SOCKS5 address.
    let address = if conf.proxy.contains("://") {
        conf.proxy.clone()
    } else {
        format!("socks5://{}", conf.proxy)
    };
    let parsed =
        url::Url::parse(&address).map_err(|_| anyhow!("http_proxy_configuration_invalid"))?;
    if !matches!(parsed.scheme(), "http" | "https" | "socks5")
        || parsed.host_str().is_none()
        || parsed.port() == Some(0)
        || !matches!(parsed.path(), "" | "/")
        || parsed.query().is_some()
        || parsed.fragment().is_some()
        || (!conf.username.is_empty() || !conf.password.is_empty())
            && (!parsed.username().is_empty() || parsed.password().is_some())
    {
        return Err(anyhow!("http_proxy_configuration_invalid"));
    }
    let mut proxy =
        reqwest::Proxy::all(parsed).map_err(|_| anyhow!("http_proxy_configuration_invalid"))?;
    if !conf.username.is_empty() || !conf.password.is_empty() {
        proxy = proxy.basic_auth(&conf.username, &conf.password);
    }
    Ok(proxy)
}

macro_rules! configure_http_client {
    ($builder:expr, $tls_type:expr, $proxy_conf:expr) => {{
        // Ignore ambient environment proxies: only explicit application policy.
        let mut builder = $builder
            .no_proxy()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(12))
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .pool_max_idle_per_host(2);
        match $tls_type {
            TlsType::Plain => {}
            TlsType::Rustls => {
                #[cfg(any(target_os = "android", target_os = "ios"))]
                {
                    let config = camellia_remote_protocol::verifier::client_config()
                        .map_err(|_| anyhow!("http_tls_configuration_unavailable"))?;
                    builder = builder.use_preconfigured_tls(config);
                }
                #[cfg(not(any(target_os = "android", target_os = "ios")))]
                {
                    builder = builder.use_rustls_tls();
                }
            }
        }
        if let Some(conf) = $proxy_conf {
            builder = builder.proxy(configured_proxy(conf)?);
        }
        builder
            .build()
            .map_err(|_| anyhow!("http_client_configuration_unavailable"))
    }};
}

fn create_http_client_with_tls(tls_type: TlsType) -> ResultType<SyncClient> {
    let conf = Config::get_socks();
    configure_http_client!(SyncClient::builder(), tls_type, conf.as_ref())
}

pub fn create_http_client_async_with_tls(tls_type: TlsType) -> ResultType<AsyncClient> {
    let conf = Config::get_socks();
    create_http_client_async_for_configuration(tls_type, conf.as_ref())
}

pub(crate) fn create_http_client_async_for_configuration(
    tls_type: TlsType,
    conf: Option<&Socks5Server>,
) -> ResultType<AsyncClient> {
    configure_http_client!(AsyncClient::builder(), tls_type, conf)
}

pub fn get_url_for_tls<'a>(url: &'a str, proxy_conf: &'a Option<Socks5Server>) -> &'a str {
    if TlsType::for_url(url).is_ok_and(|mode| mode == TlsType::Plain) {
        if let Some(conf) = proxy_conf {
            if conf.proxy.starts_with("https://") {
                return &conf.proxy;
            }
        }
    }
    url
}

pub fn create_http_client() -> ResultType<SyncClient> {
    // Rustls is the only encrypted backend. A HEAD probe cannot discover a
    // different supported backend and must not add traffic before a mutation.
    create_http_client_with_tls(TlsType::Rustls)
}

#[cfg(test)]
mod tests {
    use super::*;
    use camellia_remote_protocol::tokio::{
        self,
        io::{AsyncReadExt, AsyncWriteExt},
    };

    #[test]
    fn invalid_proxy_policy_returns_static_error_without_a_direct_client() {
        for proxy in [
            "ftp://127.0.0.1:1080",
            "http://127.0.0.1:99999",
            "http://[invalid]",
            "http://127.0.0.1:0",
            "http://127.0.0.1:8080/private",
            "http://127.0.0.1:8080?token=SECRET",
            "http://127.0.0.1:8080\r\nInjected: SECRET",
            "",
        ] {
            let conf = Socks5Server {
                proxy: proxy.to_owned(),
                username: "alice".to_owned(),
                password: "SECRET".to_owned(),
            };
            let error = configured_proxy(&conf).unwrap_err().to_string();
            assert_eq!(error, "http_proxy_configuration_invalid");
        }
        for proxy in [
            "127.0.0.1:1080",
            "socks5://127.0.0.1:1080",
            "http://[::1]:8080",
            "https://localhost:8443",
        ] {
            let conf = Socks5Server {
                proxy: proxy.to_owned(),
                ..Default::default()
            };
            assert!(configured_proxy(&conf).is_ok());
        }
    }

    #[tokio::test]
    async fn configured_proxy_receives_request_and_direct_endpoint_receives_nothing() {
        let direct = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let proxy = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let conf = Socks5Server {
            proxy: format!("http://{}", proxy.local_addr().unwrap()),
            username: "alice".to_owned(),
            password: "test-password".to_owned(),
        };
        let capture = tokio::spawn(async move {
            let (mut stream, _) = proxy.accept().await.unwrap();
            let mut bytes = vec![0; 4096];
            let count = stream.read(&mut bytes).await.unwrap();
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
                .await
                .unwrap();
            String::from_utf8(bytes[..count].to_vec()).unwrap()
        });
        let client =
            create_http_client_async_for_configuration(TlsType::Rustls, Some(&conf)).unwrap();
        let response = tokio::time::timeout(
            Duration::from_secs(2),
            client
                .get(format!("http://{}/private", direct.local_addr().unwrap()))
                .send(),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(response.status(), 200);
        let request = tokio::time::timeout(Duration::from_secs(2), capture)
            .await
            .unwrap()
            .unwrap();
        assert!(request.starts_with("GET http://127.0.0.1:"));
        assert!(request
            .to_ascii_lowercase()
            .contains("proxy-authorization: basic "));
        assert!(
            tokio::time::timeout(Duration::from_millis(50), direct.accept())
                .await
                .is_err()
        );
    }
}
