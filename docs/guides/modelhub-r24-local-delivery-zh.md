# ModelHub R24 本地交付与验收

## 交付范围

R24 基于 CC Switch 3.20.2，分支为 `feat/modelhub-r24`。本次只构建本地 Apple Silicon 安装包并提 PR，不创建 GitHub Release、不自动安装、不合入 main。R24-001（切换一致性）、R24-002（LaunchAgent 替换和回滚）、R24-004（手机远程会话开关）为本次实现范围；R24-003 按下面的清单选择性同步。

### 官方同步范围

对比来源为 fork `fb6be3c6`、官方稳定版 `v3.20.2` 和未发布 main `7726c834`。保留逐个 cherry-pick 的来源 SHA，选入 52 个稳定版提交和 5 个未发布补丁；数量包括测试和配套重构，不代表同等数量的功能。

- 会话统计：自动/手动扫描、Claude 大会话增量扫描、半行与重写检测、Codex resume 漏计及积压补扫。只修复统计，不替代会话迁移。
- Codex 接管与登录边界、重复托管账号校验、DeepSeek 工具目录、Grok 工具/子智能体、Moonshot/Kimi schema 兼容。
- Images API 生成/编辑代理、GPT-6 OAuth 客户端版本、Claude 经 OAuth 并行工具、格式转换前缀缓存。仅对应调用线路受益；ModelHub 上游仍须支持相关接口。
- 腾讯云 Token Plan、QwenCloud、Pi TokenHub、GLM 官方 Responses 端点及内置计价更新；已有供应商不是自动替换对象。
- 相关无障碍、国际化、模型查询地址与错误提示修复。

未发布补丁单独选入：

| 上游提交 | 目的 | 适用边界 |
| --- | --- | --- |
| `99f9dd2c` | 没有显式 provider 时也设置接管地址 | 与 R24 路由修复合并验证 |
| `e0c2fd2b` | 供应商同步保留子供应商元数据和排序 | 不覆盖 ModelHub fork 元数据 |
| `11317c62` | 保留各应用自己的重试/超时参数 | Codex 接管关闭不影响其他应用 |
| `5e0f3442` | 合并 Responses→Chat 进度与工具调用 | 不宣称修复 ModelHub 原生 Responses |
| `e0982799` | Images API 编辑与后续请求兼容 | 上游仍须支持 Images API |

未同步稳定版赞助商推广预设和上游发布/文档提交，也没有整体跟进未发布 main。未发布 Windows 用量检测、空思考块显示、DeepSeek 视觉目录等未列入上述清单的候选继续保留待评估。ModelHub 增量续接、远程压缩、429 准入、跨资源恢复和统一历史桶保留。

## 本地安装方式

完整安装需要同一目录中的 `install.sh`、`CC-Switch-ModelHub-3.20.2-arm64.app.zip`、`modelhub-installer-resources.tar.gz` 和 `SHA256SUMS.txt`。

先退出 CC Switch 和 ChatGPT，校验包后以当前 GUI 登录用户执行（不要用 `sudo bash`）：

```zsh
cd /absolute/path/to/R24-assets
shasum -a 256 -c SHA256SUMS.txt
/bin/bash ./install.sh --local-assets-dir "$PWD"
```

`--local-assets-dir` 从本地读取完整安装资源，不从 latest Release 取旧包。App 是本地 ad-hoc 签名版本，不宣称经过 Apple 公证；如 macOS 拦截，按系统提示在“隐私与安全性”中确认来源。不要全局关闭 Gatekeeper。安装器在需要写系统位置时申请管理员权限；AK 通过安装器无回显输入，不写进命令行。

注意：这是包含 Golden 配置的完整安装包，会替换 CC Switch 供应商数据库（包括已有自定义供应商），并在安装前备份。Codex 个性化配置默认合并；CC Switch 界面偏好保留。仅希望升级 App、保留全部现有供应商时，不要直接执行此完整安装命令。

手机远程会话默认关闭；如需开启，在 Codex 的 ModelHub 供应商编辑页中启用“支持手机远程会话”，保存并按提示重启 Codex。它不同于顶部“Codex 代理接管”开关。旧 R23 系统强制路由可能需要显式处理；不要只把 `model_provider` 改成另一个值。

## 验收边界

三类结果分别记录，不能互相替代：

1. 上游补丁与 R24 专项代码回归：类型、单元/集成测试、迁移及故障分支。
2. 安装器状态模拟和包验证：已加载 job、延迟卸载、非零退出但已消失、真实卸载失败、bootstrap/回滚失败、重复安装，本地资源校验和、架构及代码签名。配置和 launchctl 测试在隔离 fixture 中进行。
3. 用户真实环境验收：安装/升级、管理员取消、手机远程开关保存、ModelHub↔官方连续往返、托盘切换、重启 Codex 后请求/历史恢复。需要实际安装之后验证；本次构建不会触碰正在使用的配置或真实 launchd。

数据库模板与应用升级路径均采用 schema 18，升级前保留备份，回滚只处理安装事务实际改变的对象。诊断不得包含 AK、OAuth、launchd 环境明文或个人会话内容。

密钥回滚边界：安装当次失败时可使用内存快照恢复原 ModelHub AK；如果安装已完成且当时主动更换了原有 AK，之后执行备份回滚不会把旧 AK 写回 Keychain，因为普通文件备份不存储密钥。回滚会提示保留当前 AK，需要恢复旧 AK 时需重新输入。官方登录态不受此限制影响。

路由回滚失败后，保护标记会阻止继续切换、接管或把不完整的 Live 配置写回供应商。此版本没有自动修复界面，需要先核对备份并修复配置，再由支持人员清除保护标记；不要只清标记后反复切换。

## 本地验证结果（2026-09-11）

- 前端：137 个测试文件 / 1130 条通过，类型检查与格式检查通过；隔离组件预览确认新开关的位置、默认关闭和独立切换。
- Rust：3090 条通过、5 条原有测试跳过；完整 Clippy（all targets，warnings as errors）及格式检查通过。
- 安装器：143 条通过，其中新增 19 条 R24 状态与故障回归，包含完整本地资源安装、重复安装和回滚 fixture。
- 审查发现的环境变量恢复、自定义配置目录备份边界、旧 R23 回滚权限、停止代理与手机路由并发问题均已修复并补回归。
- 没有执行用户真实环境安装、管理员弹窗、真实模型请求或手机远程 E2E。未发布 Release、未合入 main。
