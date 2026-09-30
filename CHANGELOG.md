# Changelog

本仓库（`githubYiheng/retriever-ios`）是 Retriever monorepo `sdk/ios` 的只读发布镜像（`git subtree split`）；
改动一律回 monorepo。版本号遵循语义化版本：修订号 = 只修 bug；次版本 = 公开 API 只增；主版本 = 公开 API 有减或改。

## [0.1.4] - 2026-09-30

宿主发版前审查（`docs/audit/2026-09-30-prerelease/`）的 5 处 SDK 缺陷；磁盘文件格式与线协议不变。

### 修复
- **选批无限递归 → 宿主栈溢出崩溃**（A1）：出站箱有旧批、而 bootstrap 失败（`install` 为空）或某个批文件读不出时，回前台 / 网络恢复 / 定时器触发排空就递归到崩溃。现在未 bootstrap 直接停下（`not_bootstrapped`，不碰磁盘）；读不出的批跳过、试下一个，文件留在出站箱下一轮再试，全部读不出时停在 `unreadable`。
- **install.json 损坏后 SDK 永久失效**（A1）：文件读得到但解析不了（含 0 字节）时，在目录锁内原子重建（新 install_id），并在新会话写一条合成 warn（tag `rtv.install_reset`）留痕。文件存在但读不了（首次解锁前、权限）时仍不重建，本次 bootstrap 失败、稍后重试沿用原 install_id。
- **拉配置在途期间调度器 0 ms 空转**（A2）：轮询到期后请求返回前，定时器一直以 0 ms 间隔 tick（弱网下可满核数十秒）。现在请求发起时就记下尝试时刻；另加调度地板，任何候选已到期时定时器也至少等 1 s。
- **低磁盘时本地上限算成 0**（A3，ADR 0010）：可用空间 + 本方已占 < 64 MB 时，刚物化的批（含 error 批与携带的墓碑）在上传前就被驱逐。现在磁盘余量只约束 RETAINED 段与 p2 backfill 批；隔离批、p1、p0 只受 `local_cap_bytes` 约束。
- **任何 401 / 403 都进入 1 h 起倍增到 24 h 的全局暂停**（A4，ADR 0011）：边缘 / WAF / captive portal 回的 HTML 403 也会让设备停传最长一天。现在只有响应体是 JSON 对象且 `reason` 为字符串时才暂停；其余 401 / 403 与 5xx 同路径（全局退避、计毒批）。任何 2xx 确认都复位暂停倍增状态，已到期的暂停一并清掉。
- **崩溃恢复只看盘上最大 oseq / seq**（A5）：旧段已被驱逐后再崩溃，合成的 `rtv.unclean_exit` 与已上传的 oseq 撞号、永不上传，会话终态 `last_oseq` 低报。现在 oseq 高水位并入已物化位置与本会话墓碑；驱逐自己会话的段时把它的最后 seq 记进 ctx 游标，恢复时 seq 也不回退。
- 编译器兼容：`Platform.swift` 的 `weak let` 需要比 `swift-tools-version: 6.1` 更新的编译器，改为闭包捕获列表 `[weak sink]`，行为不变。

## [0.1.3] - 2026-09-30

### 新增
- `PrivacyInfo.xcprivacy` 随包分发：声明 required-reason API（文件时间戳 `C617.1`：`fstat` 读自己的段文件；磁盘空间 `E174.1`：写前检查可用空间）与收集的数据类型（User ID、Crash Data、Other Diagnostic Data；均不用于跟踪，用途 App Functionality）。宿主上传 App Store Connect 不再因 SDK 缺清单报 ITMS-91053。
- README「脱敏」：宿主可用 `Options.redact` 在落盘前掩码 URL / 交易 id 等标识（bff 的做法）。

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
