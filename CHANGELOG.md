# Changelog

本仓库（`githubYiheng/retriever-ios`）是 Retriever monorepo `sdk/ios` 的只读发布镜像（`git subtree split`）；
改动一律回 monorepo。版本号遵循语义化版本：修订号 = 只修 bug；次版本 = 公开 API 只增；主版本 = 公开 API 有减或改。

## [0.1.2] - 2026-09-30

- 删除：backfill 批的网络类型判定（原先 `backfill_networks = unmetered` 时计量网络上不传 backfill）与远程配置字段 `backfill_networks`（ADR 0009：任何能力都不再考虑网络类型，该传就传）。backfill 批与其它批按同一套队列 / 退避规则上传；服务端旧配置里残留该字段按未知字段忽略。
- 随包带 LICENSE（MIT）。

## [0.1.1] - 2026-09-29

- 修复：`retry_after_s` 巨大或负数时 `Int(v)` 可能 trap，改为饱和到 0–86 400 s（Android 复核发现）。

## [0.1.0] - 2026-09-29

首个版本。协议 v1（信封 `v: 1`），最低 iOS 15 / macOS 12，Swift 6（SPM，swift-tools 6.1）。

### 新增
- **`Retriever` 传输层本体**（零第三方依赖，gzip 用系统 zlib）：
  - `configure` / `setUser` / `log` / `flush` / `setEnabled` / `purgeLocal` / `installId` / `supportCode` /
    `uploadLevel` / `localLevel`；`Options`（uploadLevel、localLevel、dailyBatchCap、localCapBytes、redact、processName、appGroup、sdkVersion）。
  - 写入纪律：`log()` 返回前一次 `write(2)` 落盘、无用户态缓冲；进程被杀 / 崩溃不丢（真杀进程测试守着）。
  - 本地环（段 512 KB，默认 20 MB / 7 天）+ 出站箱（gzip 请求体即文件，确定性 batch_id，2xx 回显才删）。
  - 义务序号 oseq、error 带上下文（≤ 200 行 / 128 KB）、墓碑与会话终态上报、崩溃后合成 `rtv.unclean_exit`。
  - 退避与暂停（401 / 413 切分 / 429 按类别 / 503）、毒批隔离、固定驱逐顺序、远程配置（钳制、过期回落、full_dump + backfill）。
  - 目录排除备份、显式文件保护类别；进后台封段 + `beginBackgroundTask` 排空（过期必 end）。
- **`RetrieverLogger`**（本体内，无额外依赖）：给 os.Logger 项目的同名替身，同时写 os.Logger 与 Retriever（tag = category，attrs 带 subsystem）。
- **`RetrieverSwiftLog`**：`RetrieverLogHandler`（swift-log ≥ 1.12.0；metadata 扁平化）。
- **`RetrieverCocoaLumberjack`**：`RetrieverDDLogger`（CocoaLumberjack ≥ 3.10.0；宿主须关 `asyncLoggingEnabled`）。
- **示例 app**（`Example/`，xcodegen，iOS 17）：三种接入写法、flush、setUser、崩溃恢复、压测。
