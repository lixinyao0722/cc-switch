//! Safe management of the two system Codex routing defaults owned by the
//! ModelHub installer.

use crate::error::AppError;
use crate::provider::{CodexSessionHeaderAdapter, Provider};
use std::path::{Path, PathBuf};
use std::process::Command;
use toml_edit::{value, DocumentMut};

const MANAGED_CONFIG_PATH: &str = "/etc/codex/managed_config.toml";
const MODELHUB_PROVIDER: &str = "modelhub";
const MODELHUB_PROXY_URL: &str = "http://127.0.0.1:15721/v1";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodexManagedRoute {
    ModelHub,
    Official,
}

fn is_modelhub_provider(provider: &Provider) -> bool {
    provider
        .meta
        .as_ref()
        .and_then(|meta| meta.local_proxy_request_overrides.as_ref())
        .and_then(|overrides| overrides.codex_session_header_adapter)
        == Some(CodexSessionHeaderAdapter::Modelhub)
}

pub fn route_for_switch(
    previous_provider: Option<&Provider>,
    target_provider: &Provider,
) -> Option<CodexManagedRoute> {
    if is_modelhub_provider(target_provider) {
        return Some(CodexManagedRoute::ModelHub);
    }
    if crate::proxy::providers::is_codex_official_provider(target_provider)
        && previous_provider.is_some_and(is_modelhub_provider)
    {
        return Some(CodexManagedRoute::Official);
    }
    None
}

fn render_managed_config(source: &str, route: CodexManagedRoute) -> Result<String, AppError> {
    let mut document = source.parse::<DocumentMut>().map_err(|error| {
        AppError::Message(format!(
            "Codex 系统托管配置不是有效 TOML，未执行切换: {error}"
        ))
    })?;
    let root = document.as_table_mut();
    root.remove("model_provider");
    root.remove("openai_base_url");
    if route == CodexManagedRoute::ModelHub {
        root["model_provider"] = value(MODELHUB_PROVIDER);
        root["openai_base_url"] = value(MODELHUB_PROXY_URL);
    }
    Ok(document.to_string())
}

pub struct ManagedConfigSnapshot {
    content: Option<String>,
}

pub fn snapshot() -> Result<ManagedConfigSnapshot, AppError> {
    let path = target_path();
    match std::fs::read_to_string(&path) {
        Ok(content) => Ok(ManagedConfigSnapshot {
            content: Some(content),
        }),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            Ok(ManagedConfigSnapshot { content: None })
        }
        Err(error) => Err(AppError::Message(format!(
            "无法读取 Codex 系统托管配置 {}: {error}",
            path.display()
        ))),
    }
}

pub fn restore(snapshot: &ManagedConfigSnapshot) -> Result<(), AppError> {
    match snapshot.content.as_deref() {
        Some(content) => install_rendered(content),
        None => remove_target(),
    }
}

fn target_path() -> PathBuf {
    test_target_path()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(MANAGED_CONFIG_PATH))
}

#[cfg(not(test))]
fn test_target_path() -> Option<std::ffi::OsString> {
    None
}

#[cfg(test)]
fn test_target_path() -> Option<std::ffi::OsString> {
    std::env::var_os("CC_SWITCH_CODEX_MANAGED_CONFIG_PATH")
}

fn read_existing(path: &Path) -> Result<String, AppError> {
    match std::fs::read_to_string(path) {
        Ok(content) => Ok(content),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(error) => Err(AppError::Message(format!(
            "无法读取 Codex 系统托管配置 {}: {error}",
            path.display()
        ))),
    }
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

#[cfg(target_os = "macos")]
fn install_privileged(candidate: &Path, target: &Path) -> Result<(), AppError> {
    use std::os::unix::fs::MetadataExt;

    let parent = target
        .parent()
        .ok_or_else(|| AppError::Message("Codex 系统托管配置目标路径无父目录".to_string()))?;
    let temp = parent.join(format!(
        ".managed_config.toml.cc-switch.{}",
        uuid::Uuid::new_v4()
    ));
    let expected_uid = std::fs::symlink_metadata(candidate)
        .map_err(|error| AppError::Message(format!("无法校验路由候选配置: {error}")))?
        .uid();
    let command = format!(
        "/usr/bin/test -f {candidate} && /usr/bin/test ! -L {candidate} && \
         /usr/bin/stat -f %u {candidate} | /usr/bin/grep -qx {expected_uid} && \
         /usr/bin/stat -f %Lp {candidate} | /usr/bin/grep -qx 600 && \
         /usr/bin/test ! -L {parent} && \
         (/usr/bin/test ! -e {target} || (/usr/bin/test -f {target} && /usr/bin/test ! -L {target})) && \
         /bin/mkdir -p {parent} && /usr/bin/install -o root -g wheel -m 0644 {candidate} {temp} && \
         /bin/mv -f {temp} {target}",
        candidate = shell_quote(&candidate.display().to_string()),
        expected_uid = expected_uid,
        parent = shell_quote(&parent.display().to_string()),
        temp = shell_quote(&temp.display().to_string()),
        target = shell_quote(&target.display().to_string()),
    );
    let script = format!(
        "do shell script {} with administrator privileges",
        apple_script_quote(&command)
    );
    let output = Command::new("/usr/bin/osascript")
        .args(["-e", &script])
        .output()
        .map_err(|error| AppError::Message(format!("无法请求管理员授权: {error}")))?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr);
        return Err(AppError::Message(format!(
            "Codex 系统路由未切换（管理员授权被取消或写入失败）: {}",
            detail.trim()
        )));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn remove_target() -> Result<(), AppError> {
    let target = target_path();
    if test_target_path().is_some() {
        return match std::fs::remove_file(target) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(AppError::Message(error.to_string())),
        };
    }
    let parent = target
        .parent()
        .ok_or_else(|| AppError::Message("Codex 系统托管配置目标路径无父目录".to_string()))?;
    let command = format!(
        "/bin/rm -f {target} && (/usr/bin/rmdir {parent} 2>/dev/null || true)",
        target = shell_quote(&target.display().to_string()),
        parent = shell_quote(&parent.display().to_string()),
    );
    let script = format!(
        "do shell script {} with administrator privileges",
        apple_script_quote(&command)
    );
    let output = Command::new("/usr/bin/osascript")
        .args(["-e", &script])
        .output()
        .map_err(|error| AppError::Message(format!("无法请求管理员授权: {error}")))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(AppError::Message("恢复 Codex 系统路由失败".to_string()))
    }
}

#[cfg(not(target_os = "macos"))]
fn install_privileged(candidate: &Path, target: &Path) -> Result<(), AppError> {
    std::fs::create_dir_all(target.parent().unwrap_or_else(|| Path::new("/")))
        .map_err(|error| AppError::Message(error.to_string()))?;
    std::fs::copy(candidate, target)
        .map(|_| ())
        .map_err(|error| AppError::Message(error.to_string()))
}

#[cfg(not(target_os = "macos"))]
fn remove_target() -> Result<(), AppError> {
    let target = target_path();
    match std::fs::remove_file(target) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(AppError::Message(error.to_string())),
    }
}

#[cfg(target_os = "macos")]
fn apple_script_quote(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('\"', "\\\""))
}

fn install_rendered(rendered: &str) -> Result<(), AppError> {
    let target = target_path();
    if test_target_path().is_some() {
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| AppError::Message(error.to_string()))?;
        }
        std::fs::write(&target, rendered).map_err(|error| AppError::Message(error.to_string()))?;
        return Ok(());
    }

    let stage_dir =
        std::env::temp_dir().join(format!("cc-switch-codex-route-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&stage_dir)
        .map_err(|error| AppError::Message(format!("无法创建路由暂存目录: {error}")))?;
    let mut permissions = std::fs::metadata(&stage_dir)
        .map_err(|error| AppError::Message(format!("无法读取路由暂存目录权限: {error}")))?
        .permissions();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        permissions.set_mode(0o700);
        std::fs::set_permissions(&stage_dir, permissions)
            .map_err(|error| AppError::Message(format!("无法保护路由暂存目录: {error}")))?;
    }
    let candidate = stage_dir.join("managed_config.toml");
    let result = (|| {
        std::fs::write(&candidate, rendered)
            .map_err(|error| AppError::Message(format!("无法暂存路由配置: {error}")))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&candidate, std::fs::Permissions::from_mode(0o600))
                .map_err(|error| AppError::Message(format!("无法保护路由候选配置: {error}")))?;
        }
        install_privileged(&candidate, &target)
    })();
    let _ = std::fs::remove_file(&candidate);
    let _ = std::fs::remove_dir(&stage_dir);
    result
}

pub fn apply(route: CodexManagedRoute) -> Result<(), AppError> {
    let existing = read_existing(&target_path())?;
    let rendered = render_managed_config(&existing, route)?;
    if rendered == existing {
        return Ok(());
    }
    install_rendered(&rendered)
}

pub fn restart_codex_desktop() -> Result<(), AppError> {
    #[cfg(target_os = "macos")]
    {
        let status = Command::new("/usr/bin/osascript")
            .args(["-e", "tell application \"ChatGPT\" to quit"])
            .status()
            .map_err(|error| AppError::Message(format!("无法退出 Codex: {error}")))?;
        if !status.success() {
            return Err(AppError::Message("Codex 退出失败".to_string()));
        }
        Command::new("/usr/bin/open")
            .args(["-a", "ChatGPT"])
            .spawn()
            .map_err(|error| AppError::Message(format!("无法重新打开 Codex: {error}")))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modelhub_route_sets_only_owned_root_keys() {
        let source =
            "# policy\nallow_remote_control = false\n[history]\nmodel_provider = \"keep\"\n";
        let rendered = render_managed_config(source, CodexManagedRoute::ModelHub).unwrap();
        assert!(rendered.contains("model_provider = \"modelhub\""));
        assert!(rendered.contains("openai_base_url = \"http://127.0.0.1:15721/v1\""));
        assert!(rendered.contains("allow_remote_control = false"));
        assert!(rendered.contains("[history]"));
        assert!(rendered.contains("model_provider = \"keep\""));
    }

    #[test]
    fn official_route_removes_only_owned_root_keys() {
        let source = "model_provider = \"modelhub\"\nopenai_base_url = \"http://127.0.0.1:15721/v1\"\nallow_remote_control = false\n[history]\nmodel_provider = \"keep\"\n";
        let rendered = render_managed_config(source, CodexManagedRoute::Official).unwrap();
        assert!(!rendered.contains("openai_base_url"));
        assert!(rendered.contains("allow_remote_control = false"));
        assert!(rendered.contains("model_provider = \"keep\""));
    }

    fn modelhub_provider(id: &str) -> Provider {
        let mut provider =
            Provider::with_id(id.into(), "ModelHub".into(), serde_json::json!({}), None);
        provider.meta = Some(crate::provider::ProviderMeta {
            local_proxy_request_overrides: Some(crate::provider::LocalProxyRequestOverrides {
                codex_session_header_adapter: Some(CodexSessionHeaderAdapter::Modelhub),
                ..Default::default()
            }),
            ..Default::default()
        });
        provider
    }

    #[test]
    fn provider_capabilities_select_only_the_two_managed_modes() {
        let modelhub = modelhub_provider("reused-id");
        let mut official = Provider::with_id(
            "codex-official".into(),
            "Official".into(),
            serde_json::json!({}),
            None,
        );
        official.category = Some("official".into());
        let other = Provider::with_id("other".into(), "Other".into(), serde_json::json!({}), None);

        assert_eq!(
            route_for_switch(None, &modelhub),
            Some(CodexManagedRoute::ModelHub)
        );
        assert_eq!(
            route_for_switch(Some(&modelhub), &official),
            Some(CodexManagedRoute::Official)
        );
        assert_eq!(route_for_switch(Some(&other), &official), None);
    }
}
