# ModelHub Codex 代理兼容构建记录（2026-07-26）

## 来源

- 分支：`feat/modelhub-codex-proxy-compat`
- 基线：`v3.18.0@606e7bbe75db7f8285f7a3be006fac22b5d22796`
- 构建提交：`8421302`
- Worktree：`/Users/shopee/.codex/worktrees/cc-switch-modelhub-codex-proxy`

## 验证

- `pnpm typecheck`：通过。
- `pnpm format:check`：通过。
- `pnpm test:unit`：80 个文件、529 个测试通过。
- `LZMA_API_STATIC=1 cargo fmt --check`：通过。
- `LZMA_API_STATIC=1 cargo clippy --all-targets -- -D warnings`：通过。
- `LZMA_API_STATIC=1 cargo test`：核心库 2124 个测试通过、2 个忽略；全部 integration suites 通过。

## 构建

使用本地静态 liblzma，并通过临时 Tauri 配置关闭需要上游私钥的 updater artifact：

```zsh
LZMA_API_STATIC=1 pnpm tauri build \
  --bundles app \
  --config '{"bundle":{"createUpdaterArtifacts":false}}'
```

该 override 只影响本次打包，不修改仓库 `tauri.conf.json`。

## 产物

- App：`/Users/shopee/.codex/worktrees/cc-switch-modelhub-codex-proxy/src-tauri/target/release/bundle/macos/CC Switch.app`
- 版本：`3.18.0`
- Bundle identifier：`com.ccswitch.desktop`
- 架构：`arm64`
- 签名：ad-hoc，`CodeDirectory v=20400`，`TeamIdentifier=not set`
- 可执行文件 SHA-256：`5d1547edc76405ec4fc0c620697116333449663fe5caa622103507e959a5ef57`
- `codesign --verify --deep --strict`：通过。
- `otool -L`：仅系统 Framework 与 `/usr/lib` 依赖，无 `/usr/local/Cellar/xz` 或动态 `liblzma`。

CC Switch 的 ad-hoc 身份不参与 ChatGPT 原生插件的进程祖先授权链。ChatGPT 主进程与 `node_repl` 仍必须运行 OpenAI Team ID `2DC432GLL2` 的 App 内置 Codex CLI。
