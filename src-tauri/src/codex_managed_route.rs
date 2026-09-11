//! Opt-in ownership of exactly two system Codex routing defaults.

use crate::error::AppError;
use crate::provider::{CodexSessionHeaderAdapter, Provider};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
#[cfg(target_os = "macos")]
use std::process::Command;
use toml_edit::{value, DocumentMut};

const MANAGED_CONFIG_PATH: &str = "/etc/codex/managed_config.toml";
const MODELHUB_PROVIDER: &str = "custom";
#[cfg(target_os = "macos")]
const MACOS_TEST_BIN: &str = "/bin/test";
#[cfg(all(target_os = "macos", test))]
const MACOS_RMDIR_BIN: &str = "/bin/rmdir";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodexManagedRoute {
    ModelHub,
    Official,
}

pub(crate) fn is_modelhub_provider(provider: &Provider) -> bool {
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
        || previous_provider.is_some_and(is_modelhub_provider)
    {
        return Some(CodexManagedRoute::Official);
    }
    None
}

pub(crate) fn remote_sessions_enabled(provider: &Provider) -> bool {
    provider
        .meta
        .as_ref()
        .and_then(|meta| meta.local_proxy_request_overrides.as_ref())
        .and_then(|overrides| overrides.codex_remote_sessions)
        == Some(true)
}

pub(crate) fn validate_provider(provider: &Provider) -> Result<(), AppError> {
    if remote_sessions_enabled(provider) && !is_modelhub_provider(provider) {
        return Err(AppError::Message(
            "手机远程会话需要先开启 ModelHub 头适配".into(),
        ));
    }
    if !is_modelhub_provider(provider) {
        return Ok(());
    }
    let config = provider
        .settings_config
        .get("config")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let document = parse(config)?;
    if document.get("model_provider").and_then(|v| v.as_str()) != Some(MODELHUB_PROVIDER)
        || document
            .get("model_providers")
            .and_then(|v| v.get(MODELHUB_PROVIDER))
            .and_then(|v| v.as_table_like())
            .is_none()
    {
        return Err(AppError::Message("ModelHub 配置必须使用 model_provider = \"custom\" 并包含 [model_providers.custom]；路由未修改".into()));
    }
    Ok(())
}

fn parse(source: &str) -> Result<DocumentMut, AppError> {
    source
        .parse::<DocumentMut>()
        .map_err(|_| AppError::Message("Codex 路由配置不是有效 TOML，未修改路由".into()))
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
struct RouteKeys {
    model_provider: Option<String>,
    openai_base_url: Option<String>,
}

impl RouteKeys {
    fn read(document: &DocumentMut) -> Result<Self, AppError> {
        let read = |key| {
            document
                .get(key)
                .map(|item| {
                    item.as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| AppError::Message("系统路由键不是字符串；未修改策略".into()))
                })
                .transpose()
        };
        Ok(Self {
            model_provider: read("model_provider")?,
            openai_base_url: read("openai_base_url")?,
        })
    }
    fn write(&self, document: &mut DocumentMut) {
        for (key, setting) in [
            ("model_provider", &self.model_provider),
            ("openai_base_url", &self.openai_base_url),
        ] {
            match setting {
                Some(setting) => document[key] = value(setting),
                None => {
                    document.remove(key);
                }
            }
        }
    }
    fn legacy_r23(&self) -> bool {
        matches!(self.model_provider.as_deref(), Some("modelhub" | "custom"))
            && self.openai_base_url.as_deref() == Some("http://127.0.0.1:15721/v1")
    }
    fn forces_local_route(&self) -> bool {
        matches!(self.model_provider.as_deref(), Some("modelhub" | "custom"))
            || self.openai_base_url.as_ref().is_some_and(|url| {
                url::Url::parse(url).ok().is_some_and(|url| {
                    matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"))
                })
            })
    }
}

/// No credentials, policy document or provider settings are stored here.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Ownership {
    version: u8,
    target: String,
    previous: RouteKeys,
    installed: RouteKeys,
}

pub(crate) fn ensure_can_disable_takeover() -> Result<(), AppError> {
    if ownership_path()
        .try_exists()
        .map_err(|e| AppError::Message(e.to_string()))?
    {
        return Err(AppError::Message(
            "手机远程会话仍依赖本地代理；请先关闭当前卡片的手机远程开关，再关闭 Codex 接管".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
pub(crate) static FAIL_NEXT_MANAGED_WRITE: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);
#[cfg(test)]
static FAIL_NEXT_MANAGED_READBACK: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

fn ownership_path() -> PathBuf {
    #[cfg(test)]
    if let Some(path) = test_target_path() {
        return PathBuf::from(path).with_extension("cc-switch-owner.json");
    }
    crate::config::get_app_config_dir().join("codex-remote-route-owner.json")
}

pub(crate) struct ManagedRouteTransaction {
    source: Option<String>,
    before: RouteKeys,
    after: RouteKeys,
    ownership_before: Option<Vec<u8>>,
    ownership_after: Option<Vec<u8>>,
    modified: bool,
    ownership_modified: bool,
    existed: bool,
}

impl ManagedRouteTransaction {
    pub(crate) fn prepare(provider: &Provider, proxy_url: &str) -> Result<Self, AppError> {
        validate_provider(provider)?;
        let ownership_before = match std::fs::read(ownership_path()) {
            Ok(bytes) => Some(bytes),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => {
                return Err(AppError::Message(format!(
                    "无法读取远程路由所有权: {error}"
                )))
            }
        };
        let enabled = remote_sessions_enabled(provider);
        // An ordinary default-off ModelHub card does not even read system policy.
        if !enabled
            && ownership_before.is_none()
            && !crate::proxy::providers::is_codex_official_provider(provider)
        {
            return Ok(Self {
                source: None,
                before: RouteKeys::default(),
                after: RouteKeys::default(),
                ownership_before: None,
                ownership_after: None,
                modified: false,
                ownership_modified: false,
                existed: false,
            });
        }
        let source = read_existing(&target_path())?;
        let before = RouteKeys::read(&parse(&source)?)?;
        let ownership: Option<Ownership> = ownership_before
            .as_ref()
            .map(|bytes| {
                serde_json::from_slice(bytes)
                    .map_err(|_| AppError::Message("远程路由所有权记录损坏；未修改系统策略".into()))
            })
            .transpose()?;
        if let Some(owner) = &ownership {
            if owner.version != 1
                || owner.target != target_path().to_string_lossy()
                || owner.installed != before
            {
                return Err(AppError::Message(
                    "系统路由已被其他程序修改；请先检查策略，CC Switch 未覆盖它".into(),
                ));
            }
        }
        let (after, next_owner) = if enabled {
            // Explicit opt-in may migrate precisely the known R23 two-key pattern.
            // Unknown system overrides are administrator policy, not ours to adopt.
            let previous = match &ownership {
                Some(owner) => owner.previous.clone(),
                None if before == RouteKeys::default() || before.legacy_r23() => {
                    RouteKeys::default()
                }
                None => {
                    return Err(AppError::Message(
                        "系统已有非 CC Switch 路由策略；请管理员处理后再启用手机远程会话".into(),
                    ))
                }
            };
            let url = url::Url::parse(proxy_url)
                .map_err(|_| AppError::Message("本地代理地址无效".into()))?;
            if url.scheme() != "http"
                || !matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"))
                || !url.username().is_empty()
                || url.password().is_some()
                || url.query().is_some()
                || url.fragment().is_some()
            {
                return Err(AppError::Message(
                    "远程会话必须使用无凭据的本机代理地址".into(),
                ));
            }
            let installed = RouteKeys {
                model_provider: Some(MODELHUB_PROVIDER.into()),
                openai_base_url: Some(proxy_url.into()),
            };
            let owner = Ownership {
                version: 1,
                target: target_path().to_string_lossy().into_owned(),
                previous,
                installed: installed.clone(),
            };
            (
                installed,
                Some(serde_json::to_vec(&owner).map_err(|e| AppError::Message(e.to_string()))?),
            )
        } else if let Some(owner) = ownership {
            (owner.previous, None)
        } else {
            if before.forces_local_route() {
                return Err(AppError::Message("系统仍强制使用旧的本地路由，尚未切换 Official。请在 ModelHub 卡片启用一次手机远程会话以迁移 R23 路由，再关闭；其他策略请联系管理员".into()));
            }
            (before.clone(), None)
        };
        let existed = target_path()
            .try_exists()
            .map_err(|e| AppError::Message(e.to_string()))?;
        Ok(Self {
            source: Some(source),
            before,
            after,
            ownership_before,
            ownership_after: next_owner,
            modified: false,
            ownership_modified: false,
            existed,
        })
    }

    pub(crate) fn apply(&mut self) -> Result<(), AppError> {
        if self.before != self.after {
            let current = read_existing(&target_path())?;
            if Some(current.as_str()) != self.source.as_deref() {
                return Err(AppError::Message(
                    "系统配置在授权前发生变化，请重试；未修改路由".into(),
                ));
            }
            let mut document = parse(&current)?;
            self.after.write(&mut document);
            install_rendered(Some(&document.to_string()), &current, self.existed)?;
            self.modified = true;
            #[cfg(test)]
            if FAIL_NEXT_MANAGED_READBACK.swap(false, std::sync::atomic::Ordering::SeqCst) {
                return Err(AppError::Message(
                    "injected managed readback failure".into(),
                ));
            }
            if read_existing(&target_path())? != document.to_string() {
                return Err(AppError::Message(
                    "系统路由写入后的读回不一致，已取消 Live 切换".into(),
                ));
            }
        }
        if self.ownership_before != self.ownership_after {
            write_ownership(self.ownership_after.as_deref())?;
            self.ownership_modified = true;
        }
        Ok(())
    }

    pub(crate) fn rollback(&mut self) -> Result<(), AppError> {
        if self.modified {
            let current = read_existing(&target_path())?;
            let mut document = parse(&current)?;
            if RouteKeys::read(&document)? != self.after {
                return Err(AppError::Message(
                    "回滚时系统路由已被其他程序修改，未覆盖；请检查系统路由".into(),
                ));
            }
            self.before.write(&mut document);
            let rendered = document.to_string();
            install_rendered(
                if !self.existed && rendered.trim().is_empty() {
                    None
                } else {
                    Some(&rendered)
                },
                &current,
                true,
            )?;
            self.modified = false;
        }
        if self.ownership_modified {
            write_ownership(self.ownership_before.as_deref())?;
            self.ownership_modified = false;
        }
        Ok(())
    }
}

fn write_ownership(bytes: Option<&[u8]>) -> Result<(), AppError> {
    let path = ownership_path();
    match bytes {
        Some(bytes) => crate::config::atomic_write(&path, bytes),
        None => match std::fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(AppError::io(&path, error)),
        },
    }
}

fn target_path() -> PathBuf {
    #[cfg(test)]
    if test_target_path().is_none() {
        return crate::config::get_home_dir().join(".cc-switch-test/managed_config.toml");
    }
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

#[cfg(target_os = "macos")]
fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

#[cfg(target_os = "macos")]
fn install_privileged(
    candidate: &Path,
    target: &Path,
    expected: &str,
    existed: bool,
    remove: bool,
) -> Result<(), AppError> {
    use sha2::{Digest, Sha256};
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
    let compare = if existed {
        format!("/usr/bin/shasum -a 256 {target} | /usr/bin/awk '{{print $1}}' | /usr/bin/grep -qx {digest:x}",
            target = shell_quote(&target.display().to_string()), digest = Sha256::digest(expected.as_bytes()))
    } else {
        format!(
            "{MACOS_TEST_BIN} ! -e {}",
            shell_quote(&target.display().to_string())
        )
    };
    let commit = if remove {
        format!("/bin/rm -f {}", shell_quote(&target.display().to_string()))
    } else {
        format!("/bin/mkdir -p {parent} && /usr/bin/install -o root -g wheel -m 0644 {candidate} {temp} && /bin/mv -f {temp} {target}",
            parent = shell_quote(&parent.display().to_string()), candidate = shell_quote(&candidate.display().to_string()),
            temp = shell_quote(&temp.display().to_string()), target = shell_quote(&target.display().to_string()))
    };
    let command = format!(
        "{test_bin} -f {candidate} && {test_bin} ! -L {candidate} && \
         /usr/bin/stat -f %u {candidate} | /usr/bin/grep -qx {expected_uid} && \
         /usr/bin/stat -f %Lp {candidate} | /usr/bin/grep -qx 600 && \
         {test_bin} ! -L {parent} && \
         ({test_bin} ! -e {target} || ({test_bin} -f {target} && {test_bin} ! -L {target})) && \
         {compare} && {commit}",
        test_bin = MACOS_TEST_BIN,
        candidate = shell_quote(&candidate.display().to_string()),
        expected_uid = expected_uid,
        parent = shell_quote(&parent.display().to_string()),
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

#[cfg(not(target_os = "macos"))]
fn install_privileged(
    candidate: &Path,
    target: &Path,
    expected: &str,
    existed: bool,
    remove: bool,
) -> Result<(), AppError> {
    if target.exists() != existed || read_existing(target)? != expected {
        return Err(AppError::Message(
            "系统配置在授权期间发生变化，未修改路由".into(),
        ));
    }
    if remove {
        return std::fs::remove_file(target).map_err(|e| AppError::Message(e.to_string()));
    }
    std::fs::create_dir_all(target.parent().unwrap_or_else(|| Path::new("/")))
        .map_err(|error| AppError::Message(error.to_string()))?;
    std::fs::copy(candidate, target)
        .map(|_| ())
        .map_err(|error| AppError::Message(error.to_string()))
}

#[cfg(target_os = "macos")]
fn apple_script_quote(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('\"', "\\\""))
}

fn install_rendered(rendered: Option<&str>, expected: &str, existed: bool) -> Result<(), AppError> {
    let target = target_path();
    if cfg!(test) {
        #[cfg(test)]
        if FAIL_NEXT_MANAGED_WRITE.swap(false, std::sync::atomic::Ordering::SeqCst) {
            return Err(AppError::Message(
                "injected managed authorization cancellation".into(),
            ));
        }
        if target.exists() != existed || read_existing(&target)? != expected {
            return Err(AppError::Message(
                "系统配置在授权期间发生变化，未修改路由".into(),
            ));
        }
        let Some(rendered) = rendered else {
            return std::fs::remove_file(&target).map_err(|e| AppError::Message(e.to_string()));
        };
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
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = std::fs::metadata(&stage_dir)
            .map_err(|error| AppError::Message(format!("无法读取路由暂存目录权限: {error}")))?
            .permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(&stage_dir, permissions)
            .map_err(|error| AppError::Message(format!("无法保护路由暂存目录: {error}")))?;
    }
    let candidate = stage_dir.join("managed_config.toml");
    let result = (|| {
        std::fs::write(&candidate, rendered.unwrap_or_default())
            .map_err(|error| AppError::Message(format!("无法暂存路由配置: {error}")))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&candidate, std::fs::Permissions::from_mode(0o600))
                .map_err(|error| AppError::Message(format!("无法保护路由候选配置: {error}")))?;
        }
        install_privileged(&candidate, &target, expected, existed, rendered.is_none())
    })();
    let _ = std::fs::remove_file(&candidate);
    let _ = std::fs::remove_dir(&stage_dir);
    result
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

    fn render_managed_config(source: &str, route: CodexManagedRoute) -> Result<String, AppError> {
        let mut document = parse(source)?;
        let keys = if route == CodexManagedRoute::ModelHub {
            RouteKeys {
                model_provider: Some(MODELHUB_PROVIDER.into()),
                openai_base_url: Some("http://127.0.0.1:18493/v1".into()),
            }
        } else {
            RouteKeys::default()
        };
        keys.write(&mut document);
        Ok(document.to_string())
    }

    #[test]
    fn modelhub_route_sets_only_owned_root_keys() {
        let source =
            "# policy\nallow_remote_control = false\n[history]\nmodel_provider = \"keep\"\n";
        let rendered = render_managed_config(source, CodexManagedRoute::ModelHub).unwrap();
        assert!(rendered.contains("model_provider = \"custom\""));
        assert!(rendered.contains("openai_base_url = \"http://127.0.0.1:18493/v1\""));
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
        let mut provider = Provider::with_id(
            id.into(),
            "ModelHub".into(),
            serde_json::json!({
                "config": include_str!("../../scripts/modelhub-installer/templates/modelhub-provider.toml")
            }),
            None,
        );
        provider.meta = Some(crate::provider::ProviderMeta {
            local_proxy_request_overrides: Some(crate::provider::LocalProxyRequestOverrides {
                codex_session_header_adapter: Some(CodexSessionHeaderAdapter::Modelhub),
                ..Default::default()
            }),
            ..Default::default()
        });
        provider
    }

    struct ManagedTestEnv {
        _dir: tempfile::TempDir,
        old: Option<std::ffi::OsString>,
    }

    impl ManagedTestEnv {
        fn new() -> Self {
            let dir = tempfile::tempdir().unwrap();
            let old = std::env::var_os("CC_SWITCH_CODEX_MANAGED_CONFIG_PATH");
            std::env::set_var(
                "CC_SWITCH_CODEX_MANAGED_CONFIG_PATH",
                dir.path().join("managed.toml"),
            );
            Self { _dir: dir, old }
        }
    }

    impl Drop for ManagedTestEnv {
        fn drop(&mut self) {
            match &self.old {
                Some(old) => std::env::set_var("CC_SWITCH_CODEX_MANAGED_CONFIG_PATH", old),
                None => std::env::remove_var("CC_SWITCH_CODEX_MANAGED_CONFIG_PATH"),
            }
            FAIL_NEXT_MANAGED_WRITE.store(false, std::sync::atomic::Ordering::SeqCst);
            FAIL_NEXT_MANAGED_READBACK.store(false, std::sync::atomic::Ordering::SeqCst);
        }
    }

    fn opt_in(provider: &mut Provider, enabled: bool) {
        provider
            .meta
            .as_mut()
            .unwrap()
            .local_proxy_request_overrides
            .as_mut()
            .unwrap()
            .codex_remote_sessions = Some(enabled);
    }

    #[test]
    #[serial_test::serial]
    fn remote_default_off_does_not_read_write_or_create_policy() {
        let _env = ManagedTestEnv::new();
        let provider = modelhub_provider("modelhub");
        ManagedRouteTransaction::prepare(&provider, "")
            .unwrap()
            .apply()
            .unwrap();
        assert!(!target_path().exists());
        assert!(!ownership_path().exists());
        std::fs::write(target_path(), "invalid secret policy [[[[").unwrap();
        ManagedRouteTransaction::prepare(&provider, "")
            .unwrap()
            .apply()
            .unwrap();
        assert_eq!(
            read_existing(&target_path()).unwrap(),
            "invalid secret policy [[[["
        );
    }

    #[test]
    #[serial_test::serial]
    fn remote_opt_in_uses_r23_custom_table_and_actual_port_then_restores_only_owned_keys() {
        let _env = ManagedTestEnv::new();
        let mut provider = modelhub_provider("different-card-id");
        let policy = "# enterprise policy\nallow_remote_control = false\n[history]\nmodel_provider = \"keep\"\n";
        std::fs::write(target_path(), policy).unwrap();
        opt_in(&mut provider, true);
        ManagedRouteTransaction::prepare(&provider, "http://127.0.0.1:28461/v1")
            .unwrap()
            .apply()
            .unwrap();
        let document = parse(&read_existing(&target_path()).unwrap()).unwrap();
        assert_eq!(document["model_provider"].as_str(), Some("custom"));
        assert_eq!(
            document["openai_base_url"].as_str(),
            Some("http://127.0.0.1:28461/v1")
        );
        assert!(ensure_can_disable_takeover().is_err());
        let mut policy_changed = document;
        policy_changed["history"]["retention"] = value(30);
        std::fs::write(target_path(), policy_changed.to_string()).unwrap();
        opt_in(&mut provider, false);
        ManagedRouteTransaction::prepare(&provider, "")
            .unwrap()
            .apply()
            .unwrap();
        let document = parse(&read_existing(&target_path()).unwrap()).unwrap();
        assert!(document.get("model_provider").is_none());
        assert!(document.get("openai_base_url").is_none());
        assert_eq!(document["history"]["model_provider"].as_str(), Some("keep"));
        assert_eq!(document["history"]["retention"].as_integer(), Some(30));
        assert_eq!(document["allow_remote_control"].as_bool(), Some(false));
        assert!(ensure_can_disable_takeover().is_ok());
    }

    #[test]
    #[serial_test::serial]
    fn remote_unknown_policy_conflict_is_not_adopted_and_legacy_r23_requires_opt_in() {
        let _env = ManagedTestEnv::new();
        let mut provider = modelhub_provider("modelhub");
        let mut official = Provider::with_id(
            crate::database::CODEX_OFFICIAL_PROVIDER_ID.into(),
            "Official".into(),
            serde_json::json!({"auth": {}, "config": ""}),
            None,
        );
        official.category = Some("official".into());
        let legacy =
            "model_provider = \"modelhub\"\nopenai_base_url = \"http://127.0.0.1:15721/v1\"\n";
        std::fs::write(target_path(), legacy).unwrap();
        assert!(ManagedRouteTransaction::prepare(&official, "").is_err());
        assert_eq!(read_existing(&target_path()).unwrap(), legacy);
        opt_in(&mut provider, true);
        ManagedRouteTransaction::prepare(&provider, "http://127.0.0.1:28500/v1")
            .unwrap()
            .apply()
            .unwrap();
        ManagedRouteTransaction::prepare(&official, "")
            .unwrap()
            .apply()
            .unwrap();
        assert_eq!(
            RouteKeys::read(&parse(&read_existing(&target_path()).unwrap()).unwrap()).unwrap(),
            RouteKeys::default()
        );
        std::fs::write(target_path(), "model_provider = \"enterprise\"").unwrap();
        assert!(ManagedRouteTransaction::prepare(&provider, "http://127.0.0.1:28500/v1").is_err());
        assert!(!ownership_path().exists());
    }

    #[test]
    #[serial_test::serial]
    fn remote_failed_readback_rolls_back_missing_file_and_failed_authorization_does_not_restore() {
        let _env = ManagedTestEnv::new();
        let mut provider = modelhub_provider("modelhub");
        opt_in(&mut provider, true);
        let mut transaction =
            ManagedRouteTransaction::prepare(&provider, "http://127.0.0.1:28500/v1").unwrap();
        FAIL_NEXT_MANAGED_WRITE.store(true, std::sync::atomic::Ordering::SeqCst);
        assert!(transaction.apply().is_err());
        FAIL_NEXT_MANAGED_WRITE.store(true, std::sync::atomic::Ordering::SeqCst);
        transaction.rollback().unwrap();
        assert!(FAIL_NEXT_MANAGED_WRITE.swap(false, std::sync::atomic::Ordering::SeqCst));
        FAIL_NEXT_MANAGED_READBACK.store(true, std::sync::atomic::Ordering::SeqCst);
        assert!(transaction.apply().is_err());
        assert!(transaction.modified);
        transaction.rollback().unwrap();
        assert!(!target_path().exists());
        assert!(!ownership_path().exists());
    }

    #[test]
    #[serial_test::serial]
    fn remote_validation_and_source_cas_fail_before_policy_mutation() {
        let _env = ManagedTestEnv::new();
        let mut provider = modelhub_provider("modelhub");
        opt_in(&mut provider, true);
        let mut invalid = provider.clone();
        invalid.settings_config["config"] =
            serde_json::json!("model_provider = \"modelhub\"\n[model_providers.custom]");
        assert!(ManagedRouteTransaction::prepare(&invalid, "http://127.0.0.1:28500/v1").is_err());
        assert!(!target_path().exists());
        let mut transaction =
            ManagedRouteTransaction::prepare(&provider, "http://127.0.0.1:28500/v1").unwrap();
        std::fs::write(target_path(), "allow_remote_control = false").unwrap();
        assert!(transaction.apply().is_err());
        transaction.rollback().unwrap();
        assert_eq!(
            read_existing(&target_path()).unwrap(),
            "allow_remote_control = false"
        );
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
        assert_eq!(
            route_for_switch(Some(&other), &official),
            Some(CodexManagedRoute::Official)
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_test_tool_can_validate_a_regular_file() {
        let candidate = std::env::temp_dir().join(format!(
            "cc-switch-codex-route-test-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::write(&candidate, "route").expect("create candidate");

        let status = std::process::Command::new(MACOS_TEST_BIN)
            .arg("-f")
            .arg(&candidate)
            .status();

        let _ = std::fs::remove_file(&candidate);
        assert!(
            status.expect("launch the macOS test tool").success(),
            "the macOS test tool should recognize a regular file"
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_rmdir_tool_can_remove_an_empty_directory() {
        let directory = std::env::temp_dir().join(format!(
            "cc-switch-codex-route-rmdir-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir(&directory).expect("create empty directory");

        let status = std::process::Command::new(MACOS_RMDIR_BIN)
            .arg(&directory)
            .status();

        let directory_still_exists = directory.exists();
        if directory_still_exists {
            let _ = std::fs::remove_dir(&directory);
        }
        assert!(
            status.expect("launch the macOS rmdir tool").success(),
            "the macOS rmdir tool should remove an empty directory"
        );
        assert!(!directory_still_exists);
    }
}
