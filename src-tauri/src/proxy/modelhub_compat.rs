use crate::proxy::ProxyError;
use http::HeaderMap;
use http::HeaderValue;
use serde_json::Map;
use serde_json::Value;

const MAX_CODEX_IDENTITY_BYTES: usize = 256;

pub(crate) fn normalize_namespace_descriptions(body: &mut Value) -> usize {
    let mut changed = 0;
    if let Some(tools) = body.get_mut("tools").and_then(Value::as_array_mut) {
        changed += normalize_namespace_tool_list(tools);
    }
    if let Some(input) = body.get_mut("input").and_then(Value::as_array_mut) {
        for item in input {
            if item.get("type").and_then(Value::as_str) != Some("additional_tools") {
                continue;
            }
            if let Some(tools) = item.get_mut("tools").and_then(Value::as_array_mut) {
                changed += normalize_namespace_tool_list(tools);
            }
        }
    }
    changed
}

fn normalize_namespace_tool_list(tools: &mut [Value]) -> usize {
    let mut changed = 0;
    for tool in tools {
        if tool.get("type").and_then(Value::as_str) != Some("namespace") {
            continue;
        }
        let has_description = tool
            .get("description")
            .and_then(Value::as_str)
            .is_some_and(|description| !description.trim().is_empty());
        if has_description {
            continue;
        }
        let description = tool
            .get("name")
            .and_then(Value::as_str)
            .filter(|name| !name.trim().is_empty())
            .map(|name| format!("Tools in the {} namespace.", name.trim()))
            .unwrap_or_else(|| "Tools in this namespace.".to_string());
        tool["description"] = Value::String(description);
        changed += 1;
    }
    changed
}

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

pub(crate) fn is_invalid_encrypted_content_error(error: &ProxyError) -> bool {
    let ProxyError::UpstreamError {
        status: 400,
        body: Some(body),
    } = error
    else {
        return false;
    };

    let Ok(value) = serde_json::from_str::<Value>(body) else {
        return false;
    };
    if value.pointer("/error/code").and_then(Value::as_str) == Some("invalid_encrypted_content") {
        return true;
    }

    value
        .pointer("/error/message")
        .and_then(Value::as_str)
        .and_then(|message| message.split(';').next())
        .and_then(|field| field.split_once(':'))
        .is_some_and(|(label, code)| {
            label.trim().eq_ignore_ascii_case("code") && code.trim() == "invalid_encrypted_content"
        })
}

pub(crate) fn remove_encrypted_reasoning_items(body: &mut Value) -> usize {
    let Some(input) = body.get_mut("input").and_then(Value::as_array_mut) else {
        return 0;
    };

    let before = input.len();
    input.retain(|item| {
        item.get("type").and_then(Value::as_str) != Some("reasoning")
            || item.get("encrypted_content").is_none()
    });
    before.saturating_sub(input.len())
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
    use super::{
        apply_modelhub_codex_headers, is_invalid_encrypted_content_error,
        normalize_namespace_descriptions, remove_encrypted_reasoning_items,
    };
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

    #[test]
    fn invalid_encrypted_content_detection_recognizes_supported_400_error_shapes() {
        let exact = ProxyError::UpstreamError {
            status: 400,
            body: Some(
                r#"{"error":{"code":"invalid_encrypted_content","message":"could not verify"}}"#
                    .to_string(),
            ),
        };
        let wrong_status = ProxyError::UpstreamError {
            status: 422,
            body: Some(
                r#"{"error":{"code":"invalid_encrypted_content","message":"could not verify"}}"#
                    .to_string(),
            ),
        };
        let message_only = ProxyError::UpstreamError {
            status: 400,
            body: Some(
                r#"{"error":{"code":"invalid_request","message":"invalid_encrypted_content"}}"#
                    .to_string(),
            ),
        };

        assert!(is_invalid_encrypted_content_error(&exact));
        assert!(!is_invalid_encrypted_content_error(&wrong_status));
        assert!(!is_invalid_encrypted_content_error(&message_only));
        assert!(!is_invalid_encrypted_content_error(
            &ProxyError::UpstreamError {
                status: 400,
                body: Some("not-json".to_string()),
            }
        ));

        let modelhub_actual = ProxyError::UpstreamError {
            status: 400,
            body: Some(
                r#"{"error":{"message":"code: invalid_encrypted_content; message: The encrypted content for item rs_parent could not be verified. Reason: Encrypted content could not be decrypted or parsed.","type":"invalid_request_error","code":"-4003"}}"#
                    .to_string(),
            ),
        };
        assert!(is_invalid_encrypted_content_error(&modelhub_actual));
    }

    #[test]
    fn encrypted_reasoning_cleanup_preserves_visible_and_unencrypted_items() {
        let mut body = json!({
            "input": [
                {
                    "type": "reasoning",
                    "id": "rs_parent",
                    "encrypted_content": "parent-ciphertext"
                },
                {
                    "type": "reasoning",
                    "id": "rs_summary_only",
                    "summary": [{"type": "summary_text", "text": "visible summary"}]
                },
                {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "continue"}]
                }
            ]
        });

        assert_eq!(remove_encrypted_reasoning_items(&mut body), 1);
        assert_eq!(body["input"].as_array().unwrap().len(), 2);
        assert_eq!(body["input"][0]["id"], "rs_summary_only");
        assert_eq!(body["input"][1]["content"][0]["text"], "continue");
    }

    #[test]
    fn namespace_description_normalization_repairs_supported_tool_carriers() {
        let mut body = json!({
            "tools": [
                {"type": "namespace", "name": "functions", "description": "", "tools": []},
                {"type": "namespace", "name": "collaboration", "description": "Existing", "tools": []},
                {"type": "function", "name": "plain", "description": "", "parameters": {}}
            ],
            "input": [
                {
                    "type": "additional_tools",
                    "tools": [
                        {"type": "namespace", "name": "plugins", "description": "   ", "tools": []},
                        {"type": "custom", "name": "patch", "description": "", "format": {}}
                    ]
                }
            ]
        });

        assert_eq!(normalize_namespace_descriptions(&mut body), 2);
        assert_eq!(
            body["tools"][0]["description"],
            "Tools in the functions namespace."
        );
        assert_eq!(body["tools"][1]["description"], "Existing");
        assert_eq!(body["tools"][2]["description"], "");
        assert_eq!(
            body["input"][0]["tools"][0]["description"],
            "Tools in the plugins namespace."
        );
        assert_eq!(body["input"][0]["tools"][1]["description"], "");
    }

    #[test]
    fn namespace_description_normalization_uses_generic_fallback_without_name() {
        let mut body = json!({
            "tools": [{"type": "namespace", "description": null, "tools": []}]
        });

        assert_eq!(normalize_namespace_descriptions(&mut body), 1);
        assert_eq!(body["tools"][0]["description"], "Tools in this namespace.");
    }
}
