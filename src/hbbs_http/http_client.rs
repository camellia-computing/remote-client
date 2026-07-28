use camellia_remote_protocol::{
    bail,
    config::{Config, Socks5Server},
    log::{self, info},
    proxy::{Proxy, ProxyScheme},
    tls::{get_cached_tls_type, is_plain, upsert_tls_cache, TlsType},
    ResultType,
};
use reqwest::{blocking::Client as SyncClient, Client as AsyncClient};

macro_rules! configure_http_client {
    ($builder:expr, $tls_type:expr, $Client: ty) => {{
        // https://github.com/rustdesk/rustdesk/issues/11569
        // https://docs.rs/reqwest/latest/reqwest/struct.ClientBuilder.html#method.no_proxy
        let mut builder = $builder.no_proxy();

        match $tls_type {
            TlsType::Plain => {}
            TlsType::Rustls => {
                #[cfg(any(target_os = "android", target_os = "ios"))]
                match camellia_remote_protocol::verifier::client_config() {
                    Ok(client_config) => {
                        builder = builder.use_preconfigured_tls(client_config);
                    }
                    Err(e) => {
                        camellia_remote_protocol::log::error!("Failed to get client config: {}", e);
                    }
                }
                #[cfg(not(any(target_os = "android", target_os = "ios")))]
                {
                    builder = builder.use_rustls_tls();
                }
            }
        }

        let client = if let Some(conf) = Config::get_socks() {
            let proxy_result = Proxy::from_conf(&conf, None);

            match proxy_result {
                Ok(proxy) => {
                    let proxy_setup = match &proxy.intercept {
                        ProxyScheme::Http { host, .. } => {
                            reqwest::Proxy::all(format!("http://{}", host))
                        }
                        ProxyScheme::Https { host, .. } => {
                            reqwest::Proxy::all(format!("https://{}", host))
                        }
                        ProxyScheme::Socks5 { addr, .. } => {
                            reqwest::Proxy::all(&format!("socks5://{}", addr))
                        }
                    };

                    match proxy_setup {
                        Ok(mut p) => {
                            if let Some(auth) = proxy.intercept.maybe_auth() {
                                if !auth.username().is_empty() && !auth.password().is_empty() {
                                    p = p.basic_auth(auth.username(), auth.password());
                                }
                            }
                            builder = builder.proxy(p);
                            builder.build().unwrap_or_else(|e| {
                                info!("Failed to create a proxied client: {}", e);
                                <$Client>::new()
                            })
                        }
                        Err(e) => {
                            info!("Failed to set up proxy: {}", e);
                            <$Client>::new()
                        }
                    }
                }
                Err(e) => {
                    info!("Failed to configure proxy: {}", e);
                    <$Client>::new()
                }
            }
        } else {
            builder.build().unwrap_or_else(|e| {
                info!("Failed to create a client: {}", e);
                <$Client>::new()
            })
        };

        client
    }};
}

fn create_http_client_with_tls(tls_type: TlsType) -> SyncClient {
    let builder = SyncClient::builder();
    configure_http_client!(builder, tls_type, SyncClient)
}

pub fn create_http_client_async_with_tls(tls_type: TlsType) -> AsyncClient {
    let builder = AsyncClient::builder();
    configure_http_client!(builder, tls_type, AsyncClient)
}

pub fn get_url_for_tls<'a>(url: &'a str, proxy_conf: &'a Option<Socks5Server>) -> &'a str {
    if is_plain(url) {
        if let Some(conf) = proxy_conf {
            if conf.proxy.starts_with("https://") {
                return &conf.proxy;
            }
        }
    }
    url
}

fn ensure_https(url: &str) -> ResultType<()> {
    if url::Url::parse(url)?.scheme() != "https" {
        bail!("Strict HTTP client requires HTTPS: {}", url);
    }
    Ok(())
}

/// Client for update downloads: HTTPS is mandatory and certificates are always verified.
pub fn create_http_client_with_url_strict(url: &str) -> ResultType<SyncClient> {
    ensure_https(url)?;
    Ok(create_http_client_with_tls(TlsType::Rustls))
}

/// Async counterpart of [`create_http_client_with_url_strict`].
pub async fn create_http_client_async_with_url_strict(url: &str) -> ResultType<AsyncClient> {
    ensure_https(url)?;
    Ok(create_http_client_async_with_tls(TlsType::Rustls))
}

pub fn create_http_client_with_url(url: &str) -> SyncClient {
    let proxy_conf = Config::get_socks();
    let tls_url = get_url_for_tls(url, &proxy_conf);
    let tls_type = get_cached_tls_type(tls_url);
    let is_tls_type_cached = tls_type.is_some();
    let tls_type = tls_type.unwrap_or(TlsType::Rustls);
    let client = create_http_client_with_tls(tls_type);
    if is_tls_type_cached {
        return client;
    }
    if let Err(e) = client.head(url).send() {
        if e.is_request() {
            log::error!(
                "Failed to connect to server {} with {:?}, err: {:?}.",
                tls_url,
                tls_type,
                e
            );
        } else {
            log::warn!(
                "Failed to connect to server {} with {:?}, err: {}.",
                tls_url,
                tls_type,
                e
            );
        }
    } else {
        log::info!(
            "Successfully connected to server {} with {:?}",
            tls_url,
            tls_type
        );
        upsert_tls_cache(tls_url, tls_type);
    }
    client
}
