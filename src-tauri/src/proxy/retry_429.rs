use crate::provider::Retry429Config;
use crate::proxy::hyper_client::{ProxyResponse, MAX_RESPONSE_BODY_BYTES};
use crate::proxy::ProxyError;
use chrono::DateTime;
use chrono::Utc;
use http::HeaderValue;
use std::future::Future;
use std::time::Duration;

const MAX_SAME_PROVIDER_RETRIES: u8 = 10;
const MIN_BASE_DELAY_MS: u64 = 100;
const MAX_DELAY_MS: u64 = 60_000;

pub(crate) fn retry_delay(
    config: &Retry429Config,
    retry_number: u8,
    retry_after: Option<&HeaderValue>,
    now: DateTime<Utc>,
) -> Duration {
    let max_delay_ms = config.max_delay_ms.clamp(MIN_BASE_DELAY_MS, MAX_DELAY_MS);
    if config.honor_retry_after {
        if let Some(delay) = retry_after.and_then(|value| parse_retry_after(value, now)) {
            return delay.min(Duration::from_millis(max_delay_ms));
        }
    }

    let base_delay_ms = config.base_delay_ms.clamp(MIN_BASE_DELAY_MS, max_delay_ms);
    let exponent = u32::from(retry_number.saturating_sub(1).min(63));
    let multiplier = 1_u64.checked_shl(exponent).unwrap_or(u64::MAX);
    Duration::from_millis(base_delay_ms.saturating_mul(multiplier).min(max_delay_ms))
}

pub(crate) async fn send_with_retry_429<F, Fut>(
    config: Option<&Retry429Config>,
    mut send: F,
) -> Result<ProxyResponse, ProxyError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<ProxyResponse, ProxyError>>,
{
    let Some(config) = config else {
        return send().await;
    };
    let max_retries = config.max_retries.min(MAX_SAME_PROVIDER_RETRIES);
    let mut retry_number = 0_u8;

    loop {
        let response = send().await?;
        if response.status() != http::StatusCode::TOO_MANY_REQUESTS || retry_number >= max_retries {
            return Ok(response);
        }

        retry_number = retry_number.saturating_add(1);
        let retry_after = response.headers().get(http::header::RETRY_AFTER).cloned();
        if let Err(error) = response.bytes_with_limit(MAX_RESPONSE_BODY_BYTES).await {
            log::debug!(
                "[Retry429] failed to drain intermediate 429 response before retry: {error}"
            );
        }
        let delay = retry_delay(config, retry_number, retry_after.as_ref(), Utc::now());
        log::warn!(
            "[Retry429] retrying same provider after HTTP 429 ({retry_number}/{max_retries}, delay_ms={})",
            delay.as_millis()
        );
        if !delay.is_zero() {
            tokio::time::sleep(delay).await;
        }
    }
}

fn parse_retry_after(value: &HeaderValue, now: DateTime<Utc>) -> Option<Duration> {
    let value = value.to_str().ok()?.trim();
    if let Ok(seconds) = value.parse::<u64>() {
        return Some(Duration::from_secs(seconds));
    }

    let retry_at = DateTime::parse_from_rfc2822(value)
        .ok()?
        .with_timezone(&Utc);
    retry_at.signed_duration_since(now).to_std().ok()
}

#[cfg(test)]
mod tests {
    use super::retry_delay;
    use super::send_with_retry_429;
    use crate::provider::Retry429Config;
    use crate::proxy::hyper_client::ProxyResponse;
    use bytes::Bytes;
    use chrono::TimeZone;
    use http::HeaderMap;
    use http::StatusCode;
    use std::sync::Arc;
    use std::sync::Mutex;
    use std::time::Duration;

    fn config() -> Retry429Config {
        Retry429Config {
            max_retries: 10,
            base_delay_ms: 1_000,
            max_delay_ms: 30_000,
            honor_retry_after: true,
        }
    }

    #[test]
    fn retry_429_uses_exponential_backoff() {
        let now = chrono::Utc.with_ymd_and_hms(2026, 7, 26, 12, 0, 0).unwrap();

        let actual: Vec<_> = (1..=4)
            .map(|retry| retry_delay(&config(), retry, None, now))
            .collect();

        assert_eq!(
            actual,
            vec![
                Duration::from_millis(1_000),
                Duration::from_millis(2_000),
                Duration::from_millis(4_000),
                Duration::from_millis(8_000),
            ]
        );
    }

    #[test]
    fn retry_429_caps_backoff_at_30000_ms() {
        let now = chrono::Utc.with_ymd_and_hms(2026, 7, 26, 12, 0, 0).unwrap();

        assert_eq!(
            retry_delay(&config(), 10, None, now),
            Duration::from_millis(30_000)
        );
    }

    #[test]
    fn retry_429_honors_delta_retry_after() {
        let now = chrono::Utc.with_ymd_and_hms(2026, 7, 26, 12, 0, 0).unwrap();
        let retry_after = http::HeaderValue::from_static("12");

        assert_eq!(
            retry_delay(&config(), 1, Some(&retry_after), now),
            Duration::from_secs(12)
        );
    }

    #[test]
    fn retry_429_honors_http_date_retry_after() {
        let now = chrono::Utc.with_ymd_and_hms(2026, 7, 26, 12, 0, 0).unwrap();
        let retry_after = http::HeaderValue::from_static("Sun, 26 Jul 2026 12:00:05 GMT");

        assert_eq!(
            retry_delay(&config(), 1, Some(&retry_after), now),
            Duration::from_secs(5)
        );
    }

    #[test]
    fn retry_429_caps_retry_after_at_30000_ms() {
        let now = chrono::Utc.with_ymd_and_hms(2026, 7, 26, 12, 0, 0).unwrap();
        let retry_after = http::HeaderValue::from_static("120");

        assert_eq!(
            retry_delay(&config(), 1, Some(&retry_after), now),
            Duration::from_millis(30_000)
        );
    }

    #[test]
    fn retry_429_ignores_invalid_retry_after() {
        let now = chrono::Utc.with_ymd_and_hms(2026, 7, 26, 12, 0, 0).unwrap();
        let retry_after = http::HeaderValue::from_static("later");

        assert_eq!(
            retry_delay(&config(), 2, Some(&retry_after), now),
            Duration::from_millis(2_000)
        );
    }

    #[tokio::test]
    async fn same_provider_429_retries_until_success() {
        let attempts = Arc::new(Mutex::new(Vec::new()));
        let attempts_for_send = attempts.clone();
        let request_body = Bytes::from_static(br#"{"max_output_tokens":128000}"#);
        let request_headers: HeaderMap = HeaderMap::from_iter([
            ("session_id".parse().unwrap(), "session-1".parse().unwrap()),
            ("thread_id".parse().unwrap(), "thread-1".parse().unwrap()),
        ]);

        let response = send_with_retry_429(Some(&config()), || {
            let attempts = attempts_for_send.clone();
            let body = request_body.clone();
            let headers = request_headers.clone();
            async move {
                let attempt = {
                    let mut attempts = attempts.lock().unwrap();
                    attempts.push((body, headers));
                    attempts.len()
                };
                if attempt < 3 {
                    let mut headers = HeaderMap::new();
                    headers.insert("retry-after", "0".parse().unwrap());
                    Ok(ProxyResponse::buffered(
                        StatusCode::TOO_MANY_REQUESTS,
                        headers,
                        Bytes::from_static(b"rate limited"),
                    ))
                } else {
                    Ok(ProxyResponse::buffered(
                        StatusCode::OK,
                        HeaderMap::new(),
                        Bytes::from_static(b"ok"),
                    ))
                }
            }
        })
        .await
        .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let attempts = attempts.lock().unwrap();
        assert_eq!(attempts.len(), 3);
        assert!(attempts.windows(2).all(|pair| pair[0] == pair[1]));
    }

    #[tokio::test]
    async fn same_provider_429_returns_final_response_when_retries_are_exhausted() {
        let attempts = Arc::new(Mutex::new(0_u8));
        let attempts_for_send = attempts.clone();
        let config = Retry429Config {
            max_retries: 2,
            ..config()
        };

        let response = send_with_retry_429(Some(&config), || {
            let attempts = attempts_for_send.clone();
            async move {
                *attempts.lock().unwrap() += 1;
                let mut headers = HeaderMap::new();
                headers.insert("retry-after", "0".parse().unwrap());
                Ok(ProxyResponse::buffered(
                    StatusCode::TOO_MANY_REQUESTS,
                    headers,
                    Bytes::from_static(b"rate limited"),
                ))
            }
        })
        .await
        .unwrap();

        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(*attempts.lock().unwrap(), 3);
    }
}
