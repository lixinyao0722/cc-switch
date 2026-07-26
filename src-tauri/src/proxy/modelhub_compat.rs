use crate::proxy::ProxyError;
use http::HeaderMap;
use http::HeaderValue;
use serde_json::Map;
use serde_json::Value;

const MAX_CODEX_IDENTITY_BYTES: usize = 256;

pub(crate) fn apply_modelhub_codex_headers(
    inbound: &HeaderMap,
    outbound: &mut HeaderMap,
) -> Result<(), ProxyError> {
    let session = required_identity(
        inbound,
        &["session-id", "session_id", "x-session-id"],
        "session",
    )?;
    let thread = required_identity(inbound, &["thread-id", "thread_id"], "thread")?;
    let session_text = session
        .to_str()
        .map_err(|_| ProxyError::InvalidRequest("ModelHub session header is not UTF-8".into()))?;

    let mut extra = parse_extra_object(outbound)?;
    extra.insert(
        "session_id".to_string(),
        Value::String(session_text.to_string()),
    );
    let extra = HeaderValue::from_str(&Value::Object(extra).to_string())
        .map_err(|_| ProxyError::ConfigError("ModelHub extra header is invalid".into()))?;

    outbound.remove("session-id");
    outbound.remove("thread-id");
    outbound.insert("session_id", session);
    outbound.insert("thread_id", thread);
    outbound.insert("extra", extra);

    log::info!(
        "[ModelHubCompat] modelhub_session_adapter=true session_present=true thread_present=true extra_merged=true"
    );
    Ok(())
}

fn required_identity(
    headers: &HeaderMap,
    names: &[&str],
    label: &str,
) -> Result<HeaderValue, ProxyError> {
    for name in names {
        let Some(value) = headers.get(*name) else {
            continue;
        };
        let Ok(text) = value.to_str() else {
            continue;
        };
        if !text.is_empty() && text.len() <= MAX_CODEX_IDENTITY_BYTES {
            return Ok(value.clone());
        }
    }

    Err(ProxyError::InvalidRequest(format!(
        "ModelHub Codex request is missing a valid {label} header"
    )))
}

fn parse_extra_object(headers: &HeaderMap) -> Result<Map<String, Value>, ProxyError> {
    let Some(value) = headers.get("extra") else {
        return Ok(Map::new());
    };
    let text = value
        .to_str()
        .map_err(|_| ProxyError::ConfigError("ModelHub extra header is not UTF-8".into()))?;
    let value: Value = serde_json::from_str(text)
        .map_err(|_| ProxyError::ConfigError("ModelHub extra header must be valid JSON".into()))?;
    value.as_object().cloned().ok_or_else(|| {
        ProxyError::ConfigError("ModelHub extra header must be a JSON object".into())
    })
}

#[cfg(test)]
mod tests {
    use super::apply_modelhub_codex_headers;
    use crate::proxy::ProxyError;
    use http::HeaderMap;
    use serde_json::json;

    const SESSION_ID: &str = "67e55044-10b1-426f-9247-bb680e5fe0c7";
    const THREAD_ID: &str = "77e55044-10b1-426f-9247-bb680e5fe0c8";

    fn headers(entries: &[(&'static str, &'static str)]) -> HeaderMap {
        let mut headers = HeaderMap::new();
        for (name, value) in entries {
            headers.insert(*name, value.parse().unwrap());
        }
        headers
    }

    #[test]
    fn official_hyphenated_headers_become_modelhub_headers() {
        let inbound = headers(&[
            ("session-id", SESSION_ID),
            ("thread-id", THREAD_ID),
            ("x-client-request-id", THREAD_ID),
        ]);
        let mut outbound = inbound.clone();

        apply_modelhub_codex_headers(&inbound, &mut outbound).unwrap();

        assert_eq!(outbound.get("session_id").unwrap(), SESSION_ID);
        assert_eq!(outbound.get("thread_id").unwrap(), THREAD_ID);
        assert_eq!(outbound.get("x-client-request-id").unwrap(), THREAD_ID);
        assert!(outbound.get("session-id").is_none());
        assert!(outbound.get("thread-id").is_none());
        let extra: serde_json::Value =
            serde_json::from_str(outbound.get("extra").unwrap().to_str().unwrap()).unwrap();
        assert_eq!(extra, json!({ "session_id": SESSION_ID }));
    }

    #[test]
    fn legacy_private_headers_remain_compatible() {
        let inbound = headers(&[("session_id", SESSION_ID), ("thread_id", THREAD_ID)]);
        let mut outbound = inbound.clone();

        apply_modelhub_codex_headers(&inbound, &mut outbound).unwrap();

        assert_eq!(outbound.get("session_id").unwrap(), SESSION_ID);
        assert_eq!(outbound.get("thread_id").unwrap(), THREAD_ID);
        let extra: serde_json::Value =
            serde_json::from_str(outbound.get("extra").unwrap().to_str().unwrap()).unwrap();
        assert_eq!(extra, json!({ "session_id": SESSION_ID }));
    }

    #[test]
    fn static_extra_object_is_merged_and_dynamic_session_wins() {
        let inbound = headers(&[("session-id", SESSION_ID), ("thread-id", THREAD_ID)]);
        let mut outbound = inbound.clone();
        outbound.insert(
            "extra",
            r#"{"region":"internal","session_id":"stale"}"#.parse().unwrap(),
        );

        apply_modelhub_codex_headers(&inbound, &mut outbound).unwrap();

        let extra: serde_json::Value =
            serde_json::from_str(outbound.get("extra").unwrap().to_str().unwrap()).unwrap();
        assert_eq!(
            extra,
            json!({ "region": "internal", "session_id": SESSION_ID })
        );
    }

    #[test]
    fn invalid_static_extra_fails_closed() {
        let inbound = headers(&[("session-id", SESSION_ID), ("thread-id", THREAD_ID)]);
        let mut outbound = inbound.clone();
        outbound.insert("extra", "not-json".parse().unwrap());

        let error = apply_modelhub_codex_headers(&inbound, &mut outbound).unwrap_err();

        assert!(matches!(error, ProxyError::ConfigError(_)));
        assert!(!error.to_string().contains("not-json"));
    }

    #[test]
    fn missing_session_or_thread_fails_closed() {
        let missing_session = headers(&[("thread-id", THREAD_ID)]);
        let missing_thread = headers(&[("session-id", SESSION_ID)]);

        for inbound in [missing_session, missing_thread] {
            let mut outbound = inbound.clone();
            let error = apply_modelhub_codex_headers(&inbound, &mut outbound).unwrap_err();
            assert!(matches!(error, ProxyError::InvalidRequest(_)));
        }
    }

    #[test]
    fn raw_identity_is_never_prefixed_with_codex() {
        let inbound = headers(&[("x-session-id", SESSION_ID), ("thread_id", THREAD_ID)]);
        let mut outbound = HeaderMap::new();

        apply_modelhub_codex_headers(&inbound, &mut outbound).unwrap();

        assert_eq!(outbound.get("session_id").unwrap(), SESSION_ID);
        assert!(!outbound
            .get("session_id")
            .unwrap()
            .to_str()
            .unwrap()
            .starts_with("codex_"));
    }
}
