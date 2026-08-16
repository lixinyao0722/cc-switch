use crate::provider::Retry429Config;
use crate::proxy::hyper_client::{ProxyResponse, MAX_RESPONSE_BODY_BYTES};
use crate::proxy::ProxyError;
use chrono::DateTime;
use chrono::Utc;
use http::HeaderValue;
use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;
use std::time::SystemTime;
use tokio::sync::Mutex;
use tokio::sync::Notify;
use tokio::time::Instant;

const MAX_SAME_PROVIDER_RETRIES: u8 = 10;
const MIN_BASE_DELAY_MS: u64 = 100;
const MAX_DELAY_MS: u64 = 30_000;
const MAX_COOLDOWN_KEYS: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CooldownPermit {
    Open,
    Probe(u64),
}

#[derive(Debug)]
struct ProviderCooldownState {
    until: Instant,
    probe_in_flight: bool,
    generation: u64,
    notify: Arc<Notify>,
}

#[derive(Debug, Default)]
pub(crate) struct Provider429Cooldown {
    states: Mutex<HashMap<String, ProviderCooldownState>>,
}

#[derive(Clone, Debug)]
pub(crate) struct Provider429Scope {
    cooldown: Arc<Provider429Cooldown>,
    key: String,
}

impl Provider429Scope {
    pub(crate) fn new(cooldown: Arc<Provider429Cooldown>, key: impl Into<String>) -> Self {
        Self {
            cooldown,
            key: key.into(),
        }
    }
}

struct ProbeCleanup {
    scope: Option<Provider429Scope>,
    generation: Option<u64>,
    armed: bool,
}

impl ProbeCleanup {
    fn new(scope: Option<Provider429Scope>, permit: CooldownPermit) -> Self {
        let generation = match permit {
            CooldownPermit::Open => None,
            CooldownPermit::Probe(generation) => Some(generation),
        };
        Self {
            armed: generation.is_some() && scope.is_some(),
            scope,
            generation,
        }
    }

    async fn finish(&mut self) {
        if !self.armed {
            return;
        }
        if let (Some(scope), Some(generation)) = (self.scope.as_ref(), self.generation) {
            scope.cooldown.finish_probe(&scope.key, generation).await;
        }
        self.armed = false;
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for ProbeCleanup {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let (Some(scope), Some(generation)) = (self.scope.clone(), self.generation) else {
            return;
        };
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                scope.cooldown.finish_probe(&scope.key, generation).await;
            });
        }
    }
}

impl Provider429Cooldown {
    pub(crate) async fn acquire(&self, key: &str) -> CooldownPermit {
        loop {
            let wait = {
                let mut states = self.states.lock().await;
                let now = Instant::now();
                states.retain(|state_key, state| {
                    state_key == key || state.probe_in_flight || state.until > now
                });
                let Some(state) = states.get_mut(key) else {
                    return CooldownPermit::Open;
                };
                let notified = state.notify.clone().notified_owned();
                if state.until > now {
                    Some((Some(state.until), notified))
                } else if state.probe_in_flight {
                    Some((None, notified))
                } else {
                    state.probe_in_flight = true;
                    return CooldownPermit::Probe(state.generation);
                }
            };

            let Some((deadline, notified)) = wait else {
                continue;
            };
            if let Some(deadline) = deadline {
                tokio::select! {
                    _ = tokio::time::sleep_until(deadline) => {}
                    _ = notified => {}
                }
            } else {
                notified.await;
            }
        }
    }

    pub(crate) async fn record_429(&self, key: &str, delay: Duration) {
        let now = Instant::now();
        let until = now + delay;
        let (notify, evicted_notify) = {
            let mut states = self.states.lock().await;
            states.retain(|_, state| state.probe_in_flight || state.until > now);
            let evicted_notify = if states.len() >= MAX_COOLDOWN_KEYS && !states.contains_key(key) {
                if let Some(oldest_key) = states
                    .iter()
                    .filter(|(_, state)| !state.probe_in_flight)
                    .min_by_key(|(_, state)| state.until)
                    .map(|(key, _)| key.clone())
                {
                    states.remove(&oldest_key).map(|state| state.notify)
                } else {
                    log::warn!(
                        "[Retry429] cooldown state is full of active probes; skipping a new key"
                    );
                    return;
                }
            } else {
                None
            };
            let state = states
                .entry(key.to_string())
                .or_insert_with(|| ProviderCooldownState {
                    until,
                    probe_in_flight: false,
                    generation: 0,
                    notify: Arc::new(Notify::new()),
                });
            state.until = state.until.max(until);
            state.probe_in_flight = false;
            state.generation = state.generation.wrapping_add(1).max(1);
            (state.notify.clone(), evicted_notify)
        };
        if let Some(evicted_notify) = evicted_notify {
            evicted_notify.notify_waiters();
        }
        notify.notify_waiters();
    }

    pub(crate) async fn finish_probe(&self, key: &str, generation: u64) {
        let notify = {
            let mut states = self.states.lock().await;
            if states
                .get(key)
                .is_some_and(|state| state.probe_in_flight && state.generation == generation)
            {
                states.remove(key).map(|state| state.notify)
            } else {
                None
            }
        };
        if let Some(notify) = notify {
            notify.notify_waiters();
        }
    }
}

#[cfg(test)]
fn retry_delay(
    config: &Retry429Config,
    retry_number: u8,
    retry_after: Option<&HeaderValue>,
    now: DateTime<Utc>,
) -> Duration {
    retry_delay_with_jitter(config, retry_number, retry_after, now, 0)
}

fn randomized_retry_delay(
    config: &Retry429Config,
    retry_number: u8,
    retry_after: Option<&HeaderValue>,
    now: DateTime<Utc>,
) -> Duration {
    let jitter_basis_points = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|duration| duration.subsec_nanos() as u64 % 2_501)
        .unwrap_or(0);
    retry_delay_with_jitter(config, retry_number, retry_after, now, jitter_basis_points)
}

pub(crate) fn retry_delay_with_jitter(
    config: &Retry429Config,
    retry_number: u8,
    retry_after: Option<&HeaderValue>,
    now: DateTime<Utc>,
    jitter_basis_points: u64,
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
    let delay_ms = base_delay_ms.saturating_mul(multiplier);
    let jitter_ms = delay_ms
        .saturating_mul(jitter_basis_points.min(2_500))
        .checked_div(10_000)
        .unwrap_or(0);
    Duration::from_millis(delay_ms.saturating_add(jitter_ms).min(max_delay_ms))
}

pub(crate) async fn send_with_retry_429<F, Fut>(
    config: Option<&Retry429Config>,
    scope: Option<Provider429Scope>,
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
        let permit = if let Some(scope) = scope.as_ref() {
            scope.cooldown.acquire(&scope.key).await
        } else {
            CooldownPermit::Open
        };
        let mut probe_cleanup = ProbeCleanup::new(scope.clone(), permit);
        let response = match send().await {
            Ok(response) => response,
            Err(error) => {
                probe_cleanup.finish().await;
                return Err(error);
            }
        };
        if response.status() != http::StatusCode::TOO_MANY_REQUESTS {
            probe_cleanup.finish().await;
            return Ok(response);
        }

        let retry_after = response.headers().get(http::header::RETRY_AFTER).cloned();
        let next_retry_number = retry_number.saturating_add(1);
        let delay =
            randomized_retry_delay(config, next_retry_number, retry_after.as_ref(), Utc::now());
        if let Some(scope) = scope.as_ref() {
            scope.cooldown.record_429(&scope.key, delay).await;
        }
        probe_cleanup.disarm();
        if retry_number >= max_retries {
            return Ok(response);
        }

        retry_number = next_retry_number;
        if let Err(error) = response.bytes_with_limit(MAX_RESPONSE_BODY_BYTES).await {
            log::debug!(
                "[Retry429] failed to drain intermediate 429 response before retry: {error}"
            );
        }
        log::warn!(
            "[Retry429] retrying same provider after HTTP 429 ({retry_number}/{max_retries}, delay_ms={})",
            delay.as_millis()
        );
        if scope.is_none() && !delay.is_zero() {
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
    use super::retry_delay_with_jitter;
    use super::send_with_retry_429;
    use super::CooldownPermit;
    use super::Provider429Cooldown;
    use super::Provider429Scope;
    use crate::provider::Retry429Config;
    use crate::proxy::hyper_client::ProxyResponse;
    use bytes::Bytes;
    use chrono::TimeZone;
    use http::HeaderMap;
    use http::StatusCode;
    use std::sync::Arc;
    use std::sync::Mutex;
    use std::time::Duration;
    use tokio::sync::mpsc;
    use tokio::sync::oneshot;

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
    fn retry_429_caps_saved_max_delay_above_30000_ms() {
        let now = chrono::Utc.with_ymd_and_hms(2026, 7, 26, 12, 0, 0).unwrap();
        let retry_after = http::HeaderValue::from_static("120");
        let config = Retry429Config {
            max_delay_ms: 60_000,
            ..config()
        };

        assert_eq!(
            retry_delay(&config, 1, Some(&retry_after), now),
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

    #[test]
    fn retry_429_jitter_keeps_zero_basis_at_exponential_delay() {
        let now = chrono::Utc.with_ymd_and_hms(2026, 7, 26, 12, 0, 0).unwrap();

        assert_eq!(
            retry_delay_with_jitter(&config(), 3, None, now, 0),
            Duration::from_millis(4_000)
        );
    }

    #[test]
    fn retry_429_jitter_adds_at_most_twenty_five_percent_and_caps_delay() {
        let now = chrono::Utc.with_ymd_and_hms(2026, 7, 26, 12, 0, 0).unwrap();

        assert_eq!(
            retry_delay_with_jitter(&config(), 3, None, now, 2_500),
            Duration::from_millis(5_000)
        );
        assert_eq!(
            retry_delay_with_jitter(&config(), 10, None, now, 2_500),
            Duration::from_millis(30_000)
        );
    }

    #[test]
    fn retry_429_jitter_does_not_modify_retry_after() {
        let now = chrono::Utc.with_ymd_and_hms(2026, 7, 26, 12, 0, 0).unwrap();
        let retry_after = http::HeaderValue::from_static("12");

        assert_eq!(
            retry_delay_with_jitter(&config(), 1, Some(&retry_after), now, 2_500),
            Duration::from_secs(12)
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

        let response = send_with_retry_429(Some(&config()), None, || {
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

        let response = send_with_retry_429(Some(&config), None, || {
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

    #[tokio::test]
    async fn shared_cooldown_allows_only_one_recovery_probe() {
        let cooldown = Arc::new(Provider429Cooldown::default());
        cooldown
            .record_429("codex\0modelhub", Duration::from_millis(100))
            .await;
        let (sender, mut receiver) = mpsc::unbounded_channel();
        let mut tasks = Vec::new();
        for _ in 0..3 {
            let cooldown = cooldown.clone();
            let sender = sender.clone();
            tasks.push(tokio::spawn(async move {
                let permit = cooldown.acquire("codex\0modelhub").await;
                sender.send(permit).unwrap();
            }));
        }
        drop(sender);

        let first = tokio::time::timeout(Duration::from_millis(250), receiver.recv())
            .await
            .expect("one recovery probe after cooldown")
            .expect("permit");
        let CooldownPermit::Probe(first_generation) = first else {
            panic!("expected recovery probe");
        };
        assert!(
            tokio::time::timeout(Duration::from_millis(30), receiver.recv())
                .await
                .is_err()
        );

        cooldown
            .finish_probe("codex\0modelhub", first_generation)
            .await;
        let second = tokio::time::timeout(Duration::from_millis(100), receiver.recv())
            .await
            .expect("second waiter released")
            .expect("permit");
        let third = tokio::time::timeout(Duration::from_millis(100), receiver.recv())
            .await
            .expect("third waiter released")
            .expect("permit");
        assert_eq!(second, CooldownPermit::Open);
        assert_eq!(third, CooldownPermit::Open);
        for task in tasks {
            task.await.unwrap();
        }
    }

    #[tokio::test]
    async fn shared_cooldown_extends_when_recovery_probe_hits_429() {
        let cooldown = Arc::new(Provider429Cooldown::default());
        cooldown
            .record_429("codex\0modelhub", Duration::from_millis(50))
            .await;
        let first = cooldown.clone();
        let first_task = tokio::spawn(async move { first.acquire("codex\0modelhub").await });
        let second = cooldown.clone();
        let second_task = tokio::spawn(async move { second.acquire("codex\0modelhub").await });

        let first_permit = tokio::time::timeout(Duration::from_millis(150), first_task)
            .await
            .expect("first probe ready")
            .unwrap();
        let CooldownPermit::Probe(_first_generation) = first_permit else {
            panic!("expected first recovery probe");
        };

        cooldown
            .record_429("codex\0modelhub", Duration::from_millis(100))
            .await;
        let mut second_task = second_task;
        assert!(
            tokio::time::timeout(Duration::from_millis(40), &mut second_task)
                .await
                .is_err()
        );
        let second_permit = tokio::time::timeout(Duration::from_millis(150), second_task)
            .await
            .expect("extended cooldown probe ready")
            .unwrap();
        let CooldownPermit::Probe(second_generation) = second_permit else {
            panic!("expected extended cooldown probe");
        };
        cooldown
            .finish_probe("codex\0modelhub", second_generation)
            .await;
    }

    #[tokio::test]
    async fn send_with_retry_uses_one_shared_recovery_probe() {
        let cooldown = Arc::new(Provider429Cooldown::default());
        let key = "codex\0modelhub";
        cooldown.record_429(key, Duration::from_millis(50)).await;
        let scope = Provider429Scope::new(cooldown, key);
        let attempts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let active = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let max_active = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let config = Retry429Config {
            max_retries: 1,
            base_delay_ms: 100,
            max_delay_ms: 100,
            honor_retry_after: true,
        };

        let mut tasks = Vec::new();
        for _ in 0..2 {
            let scope = scope.clone();
            let attempts = attempts.clone();
            let active = active.clone();
            let max_active = max_active.clone();
            let config = config.clone();
            tasks.push(tokio::spawn(async move {
                send_with_retry_429(Some(&config), Some(scope), || {
                    let attempts = attempts.clone();
                    let active = active.clone();
                    let max_active = max_active.clone();
                    async move {
                        attempts.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                        let current = active.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
                        max_active.fetch_max(current, std::sync::atomic::Ordering::SeqCst);
                        tokio::time::sleep(Duration::from_millis(30)).await;
                        active.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                        Ok(ProxyResponse::buffered(
                            StatusCode::OK,
                            HeaderMap::new(),
                            Bytes::from_static(b"ok"),
                        ))
                    }
                })
                .await
                .unwrap()
            }));
        }

        for task in tasks {
            assert_eq!(task.await.unwrap().status(), StatusCode::OK);
        }
        assert_eq!(attempts.load(std::sync::atomic::Ordering::SeqCst), 2);
        assert_eq!(max_active.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn stale_probe_cannot_clear_a_newer_cooldown_generation() {
        let cooldown = Provider429Cooldown::default();
        let key = "codex\0modelhub";
        cooldown.record_429(key, Duration::from_millis(20)).await;
        let first = tokio::time::timeout(Duration::from_millis(100), cooldown.acquire(key))
            .await
            .expect("first probe ready");
        let CooldownPermit::Probe(first_generation) = first else {
            panic!("expected first probe");
        };

        cooldown.record_429(key, Duration::from_millis(100)).await;
        cooldown.finish_probe(key, first_generation).await;
        assert!(
            tokio::time::timeout(Duration::from_millis(40), cooldown.acquire(key))
                .await
                .is_err()
        );
        let second = tokio::time::timeout(Duration::from_millis(120), cooldown.acquire(key))
            .await
            .expect("newer cooldown probe ready");
        let CooldownPermit::Probe(second_generation) = second else {
            panic!("expected newer probe");
        };
        cooldown.finish_probe(key, second_generation).await;
    }

    #[tokio::test]
    async fn aborting_shared_recovery_probe_releases_waiters() {
        let cooldown = Arc::new(Provider429Cooldown::default());
        let key = "codex\0modelhub";
        cooldown.record_429(key, Duration::from_millis(20)).await;
        let scope = Provider429Scope::new(cooldown.clone(), key);
        let (started_sender, started_receiver) = oneshot::channel();
        let started_sender = Arc::new(Mutex::new(Some(started_sender)));
        let task = tokio::spawn(async move {
            send_with_retry_429(Some(&config()), Some(scope), || {
                let started_sender = started_sender.clone();
                async move {
                    if let Some(sender) = started_sender.lock().unwrap().take() {
                        let _ = sender.send(());
                    }
                    std::future::pending::<Result<ProxyResponse, crate::proxy::ProxyError>>().await
                }
            })
            .await
        });

        tokio::time::timeout(Duration::from_millis(100), started_receiver)
            .await
            .expect("probe request started")
            .expect("start signal");
        task.abort();
        let _ = task.await;

        let permit = tokio::time::timeout(Duration::from_millis(100), cooldown.acquire(key))
            .await
            .expect("waiters released after cancellation");
        assert_eq!(permit, CooldownPermit::Open);
    }
}
