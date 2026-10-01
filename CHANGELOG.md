# Changelog

本仓库（`githubYiheng/retriever-ios`）是 Retriever monorepo `sdk/ios` 的只读发布镜像（`git subtree split`）；
改动一律回 monorepo。版本号遵循语义化版本：修订号 = 只修 bug；次版本 = 公开 API 只增；主版本 = 公开 API 有减或改。

## [0.3.0] - 2026-10-01

configure 之前没有实例（ADR 0023）、配置缓存只记远程明确给的值（ADR 0022）、宿主误用加固（ADR 0024）、配置诊断（ADR 0025）。公开 API 签名不变（无增减）；
盘上只加可选键与新文件，0.2.x / 0.1.x 留下的状态全部照读（原地升级，不需要迁移；见下「升级」）；信封与线协议不变。

### 默认行为变化（升级前请读）
- **`configure` 之前不建实例**：此前任何 `Retriever.*` 调用都会用内置默认 Options 懒建实例，`configure` 之前的行按内置默认判定是否上传、
  并可能按默认 20 MB 驱逐、按默认级别恢复旧会话。现在 `configure` 之前的行只追加到默认 root 下的 `pre/<uuid>.jsonl`（上限 1 MB），
  `configure` 时按**本次** Options 判定、补过 `redact`、与之后的行同一个序号空间收编进会话；`configure` 之前不建会话、不联网、不驱逐、不恢复旧会话。
  进程在 `configure` 之前死掉：这些行在之后某次启动 `configure` 时收编为独立会话再上传。
- **`configure` 之前**：`installId` / `supportCode` 为 nil（此前是懒建实例的值）；`uploadLevel` / `localLevel` 读 warn / debug；
  `flush()` 回 `.pending("paused")`；`purgeLocal()` 删 pre 文件并清空默认 root。
- **`redact` 可能在 SDK 的后台线程上被调**（收编 configure 之前的行时）：须线程安全。`redact` 改 `ts` 不再生效（取回原值）。
- **`processName` / `appGroup` 只认首次 `configure`**：之后改它们被忽略、留合成 warn `rtv.reconfigure_ignored`（此前会关掉旧实例另建新实例，
  configure 之前的 `setUser`、排队中的 purge 留在旧实例上）。参数完全相同的再次 `configure` 只更新 `redact`，不再每次拉配置。
- **宿主改 Options 立即生效**：配置缓存不再把服务端回显的宿主默认当远程覆盖（响应的 `from_host`），`configure` / 再次 `configure` 的级别在调用返回时就生效。
- **fatal 节流**：距上一次 fatal 强制封段不足 10 s 的 fatal 不再各自封段 / 成批，并入 error 去抖。**flush 合并**：已有 flush 在等待且之后无新义务行时，
  并发的 flush 共享同一结果、只追加一条标记行。
- **`setUser("")` / 纯空白 = `setUser(nil)`**。
- **禁用标记读不出 = 禁用**（fail-closed）。
- **换 key / baseURL**：鉴权暂停与退避清掉、映射重发、配置缓存重拉；旧 key 的在途请求回 401 / 403 不暂停新 key。出站箱旧批照常用新 key 发。
- `flush()` 等待中被 `setEnabled(false)`：回 `.pending("disabled")`（此前 `"paused"`）。

### 新增
- 合成 warn（`synthetic: true`，不经 `redact`）：`rtv.pre_init_dropped`（没写成的行的计数：pre 文件满 / 写不进、还没有会话）、
  `rtv.root_vanished`（SDK 目录在运行中被删、已重新建会话）、`rtv.reconfigure_ignored`。
- **配置诊断**（ADR 0025）：key 为空 / 带首尾空白 / 格式或校验位不对 / 与端点环境不符、baseURL 不是 http(s)、服务端拒绝 key 时，写系统日志
  （subsystem `org.revdog.retriever`、category `diagnostics`；六个 code 见 README「接错 key / 地址时怎么看」）。只出诊断，不拦请求、不停写本地；
  唯一的行为变化：key 首尾的空白与控制字符在 `configure` 时去掉后再用（此前原样进请求头，必然 401）。

### 修复
- **没有会话时 `log()` 静默丢**（首次解锁前启动、启动时磁盘满、purge 重建失败）：改为计数并在有会话后上报。会话的 `meta.json` 写不成 = 建会话失败、稍后重试。
- **物化时段文件读不出仍推进游标**（义务行静默丢）：读失败不推进、留待下次；段文件确已不存在才先记墓碑（`corrupt`）再推进。
- **root 目录锁打不开时不加锁执行读改写**：改为本次失败、稍后重试。
- **前后台初值靠猜**：非主线程建的会话一律记成前台，后台被回收后合成假崩溃。改为进程级 tracker（首次触达起记录，非主线程先记未知、主线程补读）。
- **attrs 里的 `level` / `ctx` / `tag` / `synthetic` 键干扰判定**（批优先级、413 切分、恢复判重）：改按行内固定位置解析。
- SDK 自己取消的请求（purge、后台到期）不再计入毒批失败次数。
- SDK 的 `local_cap_bytes` 钳制缺省改为宿主值（对齐服务端权威实现）。

### 升级（0.2.x / 0.1.x → 0.3.0）
- 多数宿主无需改代码。把 `configure` 放在第一条日志之前仍是推荐写法；DI 构造期等早于 `configure` 的日志不再需要特别处理。
- 盘上新增：`pre/` 目录、`meta.json` 的 `pre` 键、`config.json` 的 `key_fp` / `base_url` / `from_host`、`backoff.json` / `mapping.json` 的 `key_fp` / `base_url`。
  旧文件缺这些键照读：指纹缺失视为与当前 key 相同并补写——升级本身不清退避 / 鉴权暂停、不重发映射、不丢配置缓存；install_id 不变，旧会话照常恢复、旧批照常上传。
- 降级回 0.2.x：`pre/` 里没收编的行不被认识、留在盘上（升回来再收编）；新增的键被旧版忽略。
- 依赖 `processName` / `appGroup` 在运行中切换的宿主（不推荐的用法）：首次 `configure` 就给出最终值。

## [0.2.0] - 2026-10-01

遗留修复批（ADR 0019「本地状态自带真实归属」、ADR 0020「宿主线程不等待 SDK」）。公开 API 只增；盘上新增可选键与 root 同级文件，0.1.x 留下的状态全部照读（原地升级，不需要迁移）；信封字段不变。

### 默认行为变化（升级前请读）
- **`log(.fatal)` 不再阻塞调用线程**（含 `RetrieverLogger.fault`、swift-log `critical`）：行仍在返回前落盘，封段与物化改在后台；进程随后死掉，下次启动恢复出同一批。
- **`purgeLocal()` 不再阻塞调用线程**：返回时清空尚未完成，新的 `installId` 要在新增的 `purgeLocal(completion:)` 回调里读；返回到清空完成之间写的行随旧状态一起删除。
- **`setEnabled(false)` 跨重启持久**：落盘为 root 同级的标记文件 `<root>.disabled`，直到 `setEnabled(true)`；禁用期间也不再拉配置。把它当「临时暂停」、指望重启恢复的宿主会变成一直禁用。
- **`RetrieverLogger` 写系统日志默认 `.private`**：Console.app / sysdiagnose 里显示 `<private>`；要明文用新的 `publicSystemLog: true`。Retriever 那一路不变。
- **`Options.appGroup` 暂不支持生产**：挂起时会持有组容器里的文件锁，可能被系统以 `0xdead10cc` 终止（重构另立 ADR）。
- 换 root / 进程名的 `configure` 不再在共享锁内等旧实例收尾（旧实例的封段在后台完成）。

### 新增
- `Retriever.isEnabled`（只读）；`Retriever.purgeLocal(completion:)`（后台线程回调）。
- `AttrValue.int(_ v: Int64)`：|v| ≤ 2^53 − 1 → 数字，超出 → 十进制字符串（静态工厂，不是新 case，宿主的穷举 switch 不受影响）。
- `RetrieverLogger(subsystem:category:publicSystemLog:)`。
- 隐私清单补 Device ID（install_id；关联用户、不用于跟踪，用途 App Functionality）——宿主同步 App Store Connect 隐私标签。

### 修复
- **会话终态被挤掉**：终态只为有义务行的会话写（空会话不再写，恢复时零行的会话目录直接删）；每批按文件顺序带最旧的 20 条，带不完留给下一批，不再删除更旧的、不再发 `closed_sessions_dropped`；`sessions.jsonl` 上限 1000 条，超出删最旧的未在途条目。
- **墓碑有损合并**：每批按文件顺序带最旧的 100 条，不合并、不改写文件；`drops.jsonl` 超 1000 条只做无损合并（同会话、同 reason、区间相接），仍超出删最旧的未在途条目——并宽不再盖住真实缺口、不再跨会话归属。
- **install.json 损坏后换新 id、旧状态挂错归属**：每个会话 `meta.json` 增可选键 `install_id`；损坏时从 meta 修复身份（不换 id、计数续上，合成 warn `rtv.install_repaired`）；没有任何副本（只在 0.1.x 升上来的首次启动恰逢损坏时可达）才清空后新建（合成 warn `rtv.install_reset`，attrs 带作废的批数 / 会话数）；有 meta 读不了按「读不了」处理，稍后重试。
- **清空不原子**：`purgeLocal` 与上一条的清空都先把 root 改名为同级 `<root>.purge-<uuid>` 再删，启动时清掉残留。
- **旧批以当前 install 上报被服务端隔离**：请求头 `X-Rtv-Install` 取批自身信封；`mapping.json` 只在 `status == "stored"` 且批属于当前 install 时记为已确认（隔离回的 200 不再让映射推迟 24 h）。
- **413 切分可能静默丢后半批**：半批改用新 batch_id（UUIDv5 `…:primary:<oseq_from>:<oseq_to>`），全部写成后才删原批；任一半写失败则删掉已写的、原批原样保留。
- **setUser 不重拉配置**：值变化即按新身份拉配置（在途请求结束后再拉一次，不被吞掉）；身份变化的那一刻缓存按过期处理，上一个用户的放大型覆盖立即回落；请求发出后身份又变了的响应丢弃。
- **恢复时段读不出就删会话**：改为不推进 cursor、不删目录、不写终态，下次启动重试。恢复时终态没写成（磁盘满等）也不再照样标记已收尾，下次启动重试。
- **jsonl 追加到一半失败留下半行**（连累下一条被丢）：失败时截回追加前的长度。
- attrs 的超长字符串值先截到预算再转义（结果不变，不再为几 MB 的值整串转义）。
- 禁用状态下恢复旧会话不再合成 `rtv.unclean_exit`（合成行也是写入）；禁用期间启动的零行会话重新启用后不补报（目录直接删）。
- 413 切分写不出时按普通失败退避（`http_413`，不计毒批），不再每 2 s 重发。

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
