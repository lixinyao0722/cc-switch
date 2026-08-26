//! Fail-closed Responses checkpoint reuse for ModelHub.
//!
//! The Codex transcript remains the source of truth. This module only replaces
//! an exact, previously acknowledged prefix with `previous_response_id`.

use crate::app_config::AppType;
use crate::provider::{ModelhubAdmissionConfig, ModelhubContextOptimizationConfig, Provider};
use http::HeaderMap;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Weak,
};
use std::time::{Duration, Instant};
use tokio::sync::{Mutex, OwnedSemaphorePermit, Semaphore};

const MAX_CHECKPOINTS: usize = 2048;
const MAX_ADMISSION_KEYS: usize = 128;

#[derive(Clone, Debug)]
struct Checkpoint {
    response_id: String,
    acknowledged_prefix: Vec<String>,
    stable_hash: String,
    created_at: Instant,
}

#[derive(Debug, Default)]
struct SessionState {
    checkpoint: Option<Checkpoint>,
    in_flight: bool,
    last_used: Option<Instant>,
}

#[derive(Debug)]
struct PendingCheckpointInner {
    store: Weak<ModelhubContextStore>,
    key: String,
    original_input_hashes: Vec<String>,
    stable_hash: String,
    provider_id: String,
    disarmed: AtomicBool,
}

impl Drop for PendingCheckpointInner {
    fn drop(&mut self) {
        if self.disarmed.load(Ordering::Acquire) {
            return;
        }
        let Some(store) = self.store.upgrade() else {
            return;
        };
        let key = self.key.clone();
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(async move {
                store.release_key_without_update(&key).await;
            });
        } else if let Ok(mut sessions) = store.sessions.try_lock() {
            if let Some(state) = sessions.get_mut(&key) {
                state.in_flight = false;
                state.last_used = Some(Instant::now());
            }
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct PendingCheckpoint {
    inner: Arc<PendingCheckpointInner>,
}

impl PendingCheckpoint {
    fn new(
        store: &Arc<ModelhubContextStore>,
        key: String,
        original_input_hashes: Vec<String>,
        stable_hash: String,
        provider_id: String,
    ) -> Self {
        Self {
            inner: Arc::new(PendingCheckpointInner {
                store: Arc::downgrade(store),
                key,
                original_input_hashes,
                stable_hash,
                provider_id,
                disarmed: AtomicBool::new(false),
            }),
        }
    }

    fn disarm(&self) {
        self.inner.disarmed.store(true, Ordering::Release);
    }
}

pub(crate) struct PreparedContext {
    pub body: Value,
    pub pending: Option<PendingCheckpoint>,
    pub mode: ContextMode,
}

impl PreparedContext {
    pub(crate) fn passthrough(body: &Value) -> Self {
        Self {
            body: body.clone(),
            pending: None,
            mode: ContextMode::Full,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum ContextMode {
    #[default]
    Full,
    Delta,
}

#[derive(Default)]
pub(crate) struct ModelhubContextStore {
    sessions: Mutex<HashMap<String, SessionState>>,
}

impl ModelhubContextStore {
    pub(crate) async fn prepare(
        self: &Arc<Self>,
        provider: &Provider,
        session_id: &str,
        client_session: bool,
        headers: &HeaderMap,
        body: &Value,
    ) -> PreparedContext {
        let Some(config) = context_config(provider) else {
            return PreparedContext::passthrough(body);
        };
        if !client_session
            || session_id.trim().is_empty()
            || body.get("previous_response_id").is_some()
        {
            return PreparedContext::passthrough(body);
        }
        // Codex's normal Responses path is streaming. Keeping non-streaming
        // callers on full history avoids coupling checkpoint completion to
        // alternate response envelopes used by probes and helper clients.
        if body.get("stream").and_then(Value::as_bool) == Some(false) {
            return PreparedContext::passthrough(body);
        }
        let Some(thread_id) = headers
            .get("thread-id")
            .or_else(|| headers.get("thread_id"))
            .and_then(|value| value.to_str().ok())
            .map(str::trim)
            .filter(|value| !value.is_empty() && value.len() <= 256)
        else {
            return PreparedContext::passthrough(body);
        };
        let Some(input) = body.get("input").and_then(Value::as_array) else {
            return PreparedContext::passthrough(body);
        };
        if super::modelhub_compat::codex_metadata_request_kind(body).is_some() {
            return PreparedContext::passthrough(body);
        }
        let Some(model) = body
            .get("model")
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty())
        else {
            return PreparedContext::passthrough(body);
        };

        let input_hashes = input.iter().map(full_hash).collect::<Vec<_>>();
        let stable_hash = stable_request_hash(body);
        let (_, account_secret) = provider.resolve_usage_credentials(&AppType::Codex);
        if account_secret.trim().is_empty() {
            return PreparedContext::passthrough(body);
        }
        let key = format!(
            "{}\0{}\0{}\0{}\0{}",
            provider.id,
            full_hash(&Value::String(account_secret)),
            session_id,
            thread_id,
            model
        );
        let now = Instant::now();
        let ttl = Duration::from_secs(config.checkpoint_ttl_seconds.clamp(60, 86_400));
        let mut sessions = self.sessions.lock().await;
        sessions.retain(|_, state| {
            state.in_flight
                || state
                    .last_used
                    .is_some_and(|last| now.duration_since(last) <= ttl)
        });
        if sessions.len() >= MAX_CHECKPOINTS && !sessions.contains_key(&key) {
            if let Some(oldest) = sessions
                .iter()
                .filter(|(_, state)| !state.in_flight)
                .min_by_key(|(_, state)| state.last_used)
                .map(|(key, _)| key.clone())
            {
                sessions.remove(&oldest);
            } else {
                log::warn!(
                    "[ModelHubContext] checkpoint capacity reached with every entry active; using full history without storing state"
                );
                return PreparedContext::passthrough(body);
            }
        }
        let state = sessions.entry(key.clone()).or_default();
        state.last_used = Some(now);
        if state.in_flight {
            return PreparedContext::passthrough(body);
        }
        state.in_flight = true;

        let pending = PendingCheckpoint::new(
            self,
            key,
            input_hashes.clone(),
            stable_hash.clone(),
            provider.id.clone(),
        );
        let Some(checkpoint) = state.checkpoint.as_ref().filter(|checkpoint| {
            now.duration_since(checkpoint.created_at) <= ttl
                && checkpoint.stable_hash == stable_hash
                && input_hashes.len() > checkpoint.acknowledged_prefix.len()
                && input_hashes.starts_with(&checkpoint.acknowledged_prefix)
        }) else {
            let mut full = body.clone();
            full["store"] = Value::Bool(true);
            return PreparedContext {
                body: full,
                pending: Some(pending),
                mode: ContextMode::Full,
            };
        };

        let suffix = input[checkpoint.acknowledged_prefix.len()..].to_vec();
        let mut optimized = body.clone();
        optimized["input"] = Value::Array(suffix);
        optimized["previous_response_id"] = Value::String(checkpoint.response_id.clone());
        optimized["store"] = Value::Bool(true);
        PreparedContext {
            body: optimized,
            pending: Some(pending),
            mode: ContextMode::Delta,
        }
    }

    pub(crate) async fn complete(&self, pending: PendingCheckpoint, response: Option<&Value>) {
        let mut sessions = self.sessions.lock().await;
        pending.disarm();
        let Some(state) = sessions.get_mut(&pending.inner.key) else {
            return;
        };
        state.in_flight = false;
        state.last_used = Some(Instant::now());
        let Some(response) = response else {
            return;
        };
        let response = if response.get("type").and_then(Value::as_str) == Some("response.completed")
        {
            response.get("response").unwrap_or(response)
        } else {
            response
        };
        if response.get("status").and_then(Value::as_str) != Some("completed") {
            return;
        }
        let Some(response_id) = response
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
        else {
            return;
        };
        let Some(output) = response.get("output").and_then(Value::as_array) else {
            return;
        };
        let mut prefix = pending.inner.original_input_hashes.clone();
        prefix.extend(output.iter().map(full_hash));
        state.checkpoint = Some(Checkpoint {
            response_id: response_id.to_string(),
            acknowledged_prefix: prefix,
            stable_hash: pending.inner.stable_hash.clone(),
            created_at: Instant::now(),
        });
    }

    pub(crate) async fn invalidate(&self, pending: PendingCheckpoint) {
        let mut sessions = self.sessions.lock().await;
        pending.disarm();
        if let Some(state) = sessions.get_mut(&pending.inner.key) {
            state.in_flight = false;
            state.checkpoint = None;
            state.last_used = Some(Instant::now());
        }
    }

    pub(crate) async fn release_without_update(&self, pending: PendingCheckpoint) {
        let mut sessions = self.sessions.lock().await;
        pending.disarm();
        Self::release_key_without_update_locked(&mut sessions, &pending.inner.key);
    }

    async fn release_key_without_update(&self, key: &str) {
        let mut sessions = self.sessions.lock().await;
        Self::release_key_without_update_locked(&mut sessions, key);
    }

    fn release_key_without_update_locked(sessions: &mut HashMap<String, SessionState>, key: &str) {
        if let Some(state) = sessions.get_mut(key) {
            state.in_flight = false;
            state.last_used = Some(Instant::now());
        }
    }

    pub(crate) fn response_belongs_to_provider(
        pending: &PendingCheckpoint,
        provider: &Provider,
    ) -> bool {
        pending.inner.provider_id == provider.id
    }
}

fn context_config(provider: &Provider) -> Option<&ModelhubContextOptimizationConfig> {
    provider
        .meta
        .as_ref()?
        .local_proxy_request_overrides
        .as_ref()?
        .context_optimization
        .as_ref()
        .filter(|config| config.enabled)
}

fn stable_request_hash(body: &Value) -> String {
    let mut stable = body.clone();
    if let Some(object) = stable.as_object_mut() {
        for key in ["input", "previous_response_id", "stream", "store"] {
            object.remove(key);
        }
    }
    full_hash(&stable)
}

fn full_hash(value: &Value) -> String {
    let canonical = super::json_canonical::canonical_json_string(value);
    Sha256::digest(canonical.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[derive(Default)]
pub(crate) struct ModelhubAdmissionController {
    gates: Mutex<HashMap<String, AdmissionGate>>,
}

struct AdmissionGate {
    capacity: u32,
    semaphore: Arc<Semaphore>,
    last_used: Instant,
}

impl ModelhubAdmissionController {
    pub(crate) async fn acquire(
        &self,
        provider: &Provider,
        body: &Value,
    ) -> Option<(OwnedSemaphorePermit, u64, u128)> {
        let config = admission_config(provider)?;
        let concurrency = config.concurrency.clamp(1, 32);
        let model = body
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let key = format!("{}\0{}", provider.id, model);
        let estimated_tokens = estimate_input_tokens(body);
        let permits = if estimated_tokens >= config.large_request_tokens {
            concurrency
        } else {
            1
        };
        let gate = {
            let mut gates = self.gates.lock().await;
            let now = Instant::now();
            gates.retain(|entry_key, gate| {
                entry_key == &key
                    || now.duration_since(gate.last_used) < Duration::from_secs(3600)
                    || gate.semaphore.available_permits() != gate.capacity as usize
            });
            if gates.len() >= MAX_ADMISSION_KEYS && !gates.contains_key(&key) {
                if let Some(oldest) = gates
                    .iter()
                    .filter(|(_, gate)| {
                        gate.semaphore.available_permits() == gate.capacity as usize
                    })
                    .min_by_key(|(_, gate)| gate.last_used)
                    .map(|(key, _)| key.clone())
                {
                    gates.remove(&oldest);
                }
            }
            let entry = gates.entry(key).or_insert_with(|| AdmissionGate {
                capacity: concurrency,
                semaphore: Arc::new(Semaphore::new(concurrency as usize)),
                last_used: now,
            });
            if entry.capacity != concurrency
                && entry.semaphore.available_permits() == entry.capacity as usize
            {
                *entry = AdmissionGate {
                    capacity: concurrency,
                    semaphore: Arc::new(Semaphore::new(concurrency as usize)),
                    last_used: now,
                };
            }
            entry.last_used = now;
            entry.semaphore.clone()
        };
        let started = Instant::now();
        let permit = gate.acquire_many_owned(permits).await.ok()?;
        Some((permit, estimated_tokens, started.elapsed().as_millis()))
    }
}

fn admission_config(provider: &Provider) -> Option<&ModelhubAdmissionConfig> {
    provider
        .meta
        .as_ref()?
        .local_proxy_request_overrides
        .as_ref()?
        .admission_control
        .as_ref()
        .filter(|config| config.enabled && config.concurrency > 0)
}

fn estimate_input_tokens(body: &Value) -> u64 {
    let bytes = body
        .get("input")
        .map(super::json_canonical::canonical_json_string)
        .map(|value| value.len() as u64)
        .unwrap_or(0);
    bytes.saturating_add(2) / 3
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::{CodexSessionHeaderAdapter, LocalProxyRequestOverrides, ProviderMeta};
    use serde_json::json;

    fn headers() -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert("thread-id", "thread-000000000000000000001".parse().unwrap());
        headers
    }

    fn provider() -> Provider {
        let mut provider = Provider::with_id(
            "modelhub".into(),
            "ModelHub".into(),
            json!({"auth": {"OPENAI_API_KEY": "test-ak"}}),
            None,
        );
        provider.meta = Some(ProviderMeta {
            local_proxy_request_overrides: Some(LocalProxyRequestOverrides {
                codex_session_header_adapter: Some(CodexSessionHeaderAdapter::Modelhub),
                context_optimization: Some(ModelhubContextOptimizationConfig {
                    enabled: true,
                    checkpoint_ttl_seconds: 3600,
                }),
                admission_control: Some(ModelhubAdmissionConfig {
                    enabled: true,
                    large_request_tokens: 4,
                    concurrency: 4,
                }),
                ..Default::default()
            }),
            ..Default::default()
        });
        provider
    }

    #[tokio::test]
    async fn exact_prefix_uses_previous_response_id_and_only_suffix() {
        let store = Arc::new(ModelhubContextStore::default());
        let provider = provider();
        let first = json!({"model":"gpt","input":[{"role":"user","content":"one"}],"stream":true});
        let prepared = store
            .prepare(&provider, "session", true, &headers(), &first)
            .await;
        assert_eq!(prepared.mode, ContextMode::Full);
        store.complete(prepared.pending.unwrap(), Some(&json!({"id":"resp_1","status":"completed","output":[{"type":"message","role":"assistant","content":"ack"}]}))).await;
        let second = json!({"model":"gpt","input":[{"role":"user","content":"one"},{"type":"message","role":"assistant","content":"ack"},{"role":"user","content":"two"}],"stream":true});
        let prepared = store
            .prepare(&provider, "session", true, &headers(), &second)
            .await;
        assert_eq!(prepared.mode, ContextMode::Delta);
        assert_eq!(prepared.body["previous_response_id"], "resp_1");
        assert_eq!(prepared.body["input"].as_array().unwrap().len(), 1);
        assert_eq!(prepared.body["store"], true);
    }

    #[tokio::test]
    async fn fork_or_option_change_falls_back_to_full_history() {
        let store = Arc::new(ModelhubContextStore::default());
        let provider = provider();
        let first = json!({"model":"gpt","tools":[{"name":"a"}],"input":[{"role":"user","content":"one"}],"stream":true});
        let prepared = store
            .prepare(&provider, "session", true, &headers(), &first)
            .await;
        store
            .complete(
                prepared.pending.unwrap(),
                Some(&json!({"id":"resp_1","status":"completed","output":[]})),
            )
            .await;
        let changed = json!({"model":"gpt","tools":[{"name":"b"}],"input":[{"role":"user","content":"different"}],"stream":true});
        let prepared = store
            .prepare(&provider, "session", true, &headers(), &changed)
            .await;
        assert_eq!(prepared.mode, ContextMode::Full);
        assert!(prepared.body.get("previous_response_id").is_none());
    }

    #[tokio::test]
    async fn different_thread_never_reuses_a_checkpoint() {
        let store = Arc::new(ModelhubContextStore::default());
        let provider = provider();
        let first = json!({"model":"gpt","input":[{"role":"user","content":"one"}],"stream":true});
        let prepared = store
            .prepare(&provider, "session", true, &headers(), &first)
            .await;
        store
            .complete(
                prepared.pending.unwrap(),
                Some(&json!({"id":"resp_1","status":"completed","output":[]})),
            )
            .await;
        let mut other_headers = HeaderMap::new();
        other_headers.insert("thread-id", "thread-000000000000000000002".parse().unwrap());
        let second = json!({"model":"gpt","input":[{"role":"user","content":"one"},{"role":"user","content":"two"}],"stream":true});
        let prepared = store
            .prepare(&provider, "session", true, &other_headers, &second)
            .await;
        assert_eq!(prepared.mode, ContextMode::Full);
        assert!(prepared.body.get("previous_response_id").is_none());
    }

    #[tokio::test]
    async fn large_requests_take_the_whole_admission_gate() {
        let controller = ModelhubAdmissionController::default();
        let permit = controller
            .acquire(
                &provider(),
                &json!({"model":"gpt","input":"a long request body"}),
            )
            .await
            .unwrap();
        assert!(permit.1 >= 4);
    }

    #[tokio::test]
    async fn explicit_cursor_and_non_streaming_requests_are_untouched() {
        let store = Arc::new(ModelhubContextStore::default());
        let provider = provider();
        let explicit = json!({"model":"gpt","previous_response_id":"caller-owned","input":[{"role":"user","content":"one"}],"stream":true});
        let prepared = store
            .prepare(&provider, "session", true, &headers(), &explicit)
            .await;
        assert_eq!(prepared.body, explicit);
        assert!(prepared.pending.is_none());

        let non_streaming =
            json!({"model":"gpt","input":[{"role":"user","content":"one"}],"stream":false});
        let prepared = store
            .prepare(&provider, "session", true, &headers(), &non_streaming)
            .await;
        assert_eq!(prepared.body, non_streaming);
        assert!(prepared.pending.is_none());
    }

    #[tokio::test]
    async fn dropping_the_last_lease_releases_in_flight_state() {
        let store = Arc::new(ModelhubContextStore::default());
        let provider = provider();
        let body = json!({"model":"gpt","input":[{"role":"user","content":"one"}],"stream":true});
        let first = store
            .prepare(&provider, "session", true, &headers(), &body)
            .await;
        assert!(first.pending.is_some());
        drop(first);
        tokio::task::yield_now().await;

        let second = store
            .prepare(&provider, "session", true, &headers(), &body)
            .await;
        assert!(
            second.pending.is_some(),
            "a cancelled request must not leave the session permanently in flight"
        );
    }

    #[tokio::test]
    async fn cancelling_cleanup_while_waiting_for_lock_keeps_drop_release_armed() {
        let store = Arc::new(ModelhubContextStore::default());
        let provider = provider();
        let body = json!({"model":"gpt","input":[{"role":"user","content":"one"}],"stream":true});
        let prepared = store
            .prepare(&provider, "session", true, &headers(), &body)
            .await;
        let pending = prepared.pending.expect("checkpoint lease");
        let held = store.sessions.lock().await;
        let store_for_cleanup = store.clone();
        let cleanup = tokio::spawn(async move {
            store_for_cleanup.release_without_update(pending).await;
        });
        tokio::task::yield_now().await;
        cleanup.abort();
        drop(held);
        tokio::task::yield_now().await;

        let next = store
            .prepare(&provider, "session", true, &headers(), &body)
            .await;
        assert!(
            next.pending.is_some(),
            "an aborted cleanup future must leave Drop armed so the session is released"
        );
    }

    #[tokio::test]
    async fn full_active_store_fails_closed_without_growing() {
        let store = Arc::new(ModelhubContextStore::default());
        let provider = provider();
        let body = json!({"model":"gpt","input":[{"role":"user","content":"one"}],"stream":true});
        let mut leases = Vec::with_capacity(MAX_CHECKPOINTS);
        for index in 0..MAX_CHECKPOINTS {
            let mut request_headers = HeaderMap::new();
            request_headers.insert("thread-id", format!("thread-{index:020}").parse().unwrap());
            let prepared = store
                .prepare(
                    &provider,
                    &format!("session-{index:020}"),
                    true,
                    &request_headers,
                    &body,
                )
                .await;
            leases.push(prepared.pending.expect("capacity lease"));
        }

        let overflow = store
            .prepare(&provider, "overflow-session", true, &headers(), &body)
            .await;
        assert!(overflow.pending.is_none());
        assert_eq!(store.sessions.lock().await.len(), MAX_CHECKPOINTS);

        drop(leases);
    }
}
