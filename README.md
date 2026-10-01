# Retriever iOS 传输层（`sdk/ios`）

Swift 6 SPM 包，iOS 15+ / macOS 12+。规格：`docs/plan/system-design.md` §3；不变式：`docs/architecture.md` §2。

| product | 依赖 | 用途 |
|---|---|---|
| `Retriever` | 无（gzip 用系统 zlib） | 传输层本体 |
| `RetrieverSwiftLog` | swift-log ≥ 1.12.0 | `RetrieverLogHandler` |
| `RetrieverCocoaLumberjack` | CocoaLumberjack ≥ 3.10.0（`CocoaLumberjackSwift`） | `RetrieverDDLogger` |

## 安装

```swift
// Package.swift
.package(url: "https://github.com/githubYiheng/retriever-ios.git", from: "0.3.0"),
// target 依赖按需选：
.product(name: "Retriever", package: "retriever-ios"),
.product(name: "RetrieverSwiftLog", package: "retriever-ios"),         // 用 swift-log 时
.product(name: "RetrieverCocoaLumberjack", package: "retriever-ios"),  // 用 CocoaLumberjack 时
```

Xcode：File → Add Package Dependencies… 填同一个 URL，Dependency Rule 选 Up to Next Major Version。
**公开仓库只读**：它是 monorepo `sdk/ios` 的 subtree split 发布镜像，issue / PR 不在那里处理，改动一律回 monorepo。
版本变更见 `CHANGELOG.md`。

## 接入

```swift
import Retriever

// application(_:didFinishLaunchingWithOptions:) 里，越早越好（之前的日志也不丢，见下节）
var o = Options(); o.uploadLevel = .warn          // 可选 .info / .debug（ADR 0004）
Retriever.configure(key: "lk_live_<app>_…", options: o)
Retriever.setUser(currentUserId)                    // 登录 / 登出时再调；nil = 未登录
Retriever.log(.error, "purchase failed", tag: "billing", attrs: ["code": .number(7)], error: err)
```

- 「上报问题」：`let r = await Retriever.flush()`。它向当前段追加一条合成行（`error`、`tag: "rtv.flush"`、`synthetic: true`，
  无视上传级别一定上传），立即封段并排空；该批 15 s 内被服务端确认 → `.stored`，否则 `.pending("offline" | "backoff" | "paused" | "timeout")`
  （`setEnabled(false)` 时、或等待中被禁用，`.pending("disabled")`；`configure` 之前 `.pending("paused")`）。`flush(includeContext: false)` 时该批不带上下文。
  已有一个 flush 在等待、且它之后没有新的义务行时，再调用会挂到同一个等待上（同一结果，不再追加标记行、不再换段）。**不要在 flush 的结果里自旋重试**。
- 用户撤回同意：`Retriever.setEnabled(false)`——不写、不传、不拉配置，**落盘、跨重启有效**，直到 `setEnabled(true)`。
  状态记在 root 同级的空标记文件 `<root>.disabled`（清空本地不会带走它）；`configure` 之前调用也生效；`Retriever.isEnabled` 读当前值。
  标记写失败（磁盘满、首次解锁前）时本进程照样禁用、稍后重试；在写成之前进程就死的话下次启动是启用的——撤回同意的宿主请在每次启动、
  `configure` 之前再调一次 `setEnabled(false)`（幂等）。在途的那一个请求不取消（数据是同意期内采集的）。
  不要把它当「临时暂停」用：重启不会恢复。标记读不出（目录不可读等）按禁用处理（fail-closed），之后每次建会话成功、每次调度唤醒重判。
- 清空本地：`Retriever.purgeLocal()`（新 install_id）。**不阻塞调用线程**：返回时清空尚未完成，`installId` 要在
  `Retriever.purgeLocal { … }` 的完成回调（后台线程）里才是新值；返回到回调之间写的行随旧状态一起删除。
  **撤回同意的完整组合 = `setEnabled(false)` + `purgeLocal()` + `setUser(nil)`**（purge 不清用户）。`configure` 之前调用同样有效（删 pre 文件、清默认 root）。
- `setUser`：清洗（剔除控制字符、截 128 B）后为空——`""`、纯空白——等同 `setUser(nil)`。
- 客服短码：`Retriever.supportCode`。生效级别（远程配置钳制后）：`Retriever.uploadLevel` / `Retriever.localLevel`，适配器用来早过滤。
- 整数 attrs（订单号、雪花 id 等）用 `.int(_:)`：`attrs: ["order": .int(Int64(orderId))]`。|v| ≤ 2^53 − 1 输出 JSON 数字，
  超出输出十进制字符串（Double 表示不了，否则会被静默改成别的数）。
- `fatal`（含 `RetrieverLogger.fault`、swift-log `critical`）：行在返回前已落盘，封段与物化在后台进行，**不阻塞调用线程**；
  进程随后死掉，下次启动会恢复并上报同一批。可以在任意线程调，**不能在 signal handler 里调**（不是 async-signal-safe）。
  节流：距上一次 fatal 强制封段不足 10 s 的 fatal 照常逐行落盘，但不再强制封段，并入 error 的去抖封段（`.fault` 当普通严重级别用的代码不会每行一批）。

## configure 之前的日志（0.3.0，ADR 0023）

`configure` 之前 SDK **不建实例**：不建会话、不起后台线程、不联网、不驱逐、不恢复旧会话。这期间的 `log()`（含适配器）一次 `write(2)`
追加到默认 root 下的 `pre/<uuid>.jsonl`（本进程一个文件，持 flock），**不丢、级别不过滤**；`configure` 时：

- 按**本次** `configure` 的 Options（叠加远程明确下发的覆盖）判定这些行：低于 `localLevel` 的丢弃、达到 `uploadLevel` 的成为义务行（带 oseq），
  与 configure 之后的行同一个序号空间、同一套封段规则（error 去抖、fatal 立即封段、用户边界）。行的 `ts` 保持写入时刻；
- 这些行在收编时**补过 `redact`**——钩子此时在 SDK 的后台线程上被调：**必须线程安全、要快**；钩子里调 `log()` 被忽略；改 `ts` 无效；
- 上限 1 MB（只管 configure 之前的行；configure 之后、收编完成之前的行照常落盘）：超出（以及磁盘满、首次解锁前写不进、
  用户切换记录写不成之后）的行不缓存，只计数，之后以合成 warn `rtv.pre_init_dropped` 上报（attrs `count` /
  `error_count` / `first_ts` / `last_ts`）。计数只在内存：进程在上报之前死掉则计数丢失（行本来就没写成）；
- 期间的 `setUser` / `setEnabled` / `purgeLocal` 照常生效（文件级）；`flush` 回 `.pending("paused")`；`installId` / `supportCode` 为 nil；
  `uploadLevel` / `localLevel` 读 warn / debug（适配器早过滤按全收）。禁用标记在、或宿主已 `setEnabled(false)` 时不写、不计数；
- **从不 configure 的进程**（例如只打日志、不上传的扩展）：每个进程留一个 pre 文件。进程内第一次建 pre 文件之前，没有活进程持有的
  旧 pre 文件总量超过 4 MB 或个数超过 8 个时，从最旧的删起（不计数）——本地占用有上限（R-5）。
- **边界**：进程在 `configure` 之前就死（例如 DI 构造期崩溃循环），那次的行留在本地，等之后某次启动走到 `configure` 才收编成一个独立会话、上传
  （没有前后台记录，不合成 `rtv.unclean_exit`）。SDK 在 `configure` 之前不知道 key，任何设计都传不出去——所以 **`configure` 仍然越早越好**，
  只是不再影响判定的正确性。
- `processName` / `appGroup` **只认首次 `configure`**：之后的 `configure` 改它们被忽略（其余参数照常生效），并留合成 warn `rtv.reconfigure_ignored`
  （attrs `field` = `process_name` | `app_group`）。参数与上次完全相同的 `configure` 只更新 `redact`，不拉配置。
- `configure` 指定 `appGroup` 时，本进程 configure 之前的行（在默认 root 的 pre 文件里）收编进 appGroup root 的会话；别的进程留下的孤儿 pre 文件由
  使用默认 root 的实例收编。

## 宿主必须知道的纪律

- **目录**：`Library/Application Support/<bundle-id>.retriever/`（`appGroup` 非空时为组容器里的 `<group>.retriever/`）。
  不要挪进 Caches / tmp，也不要自行清理；SDK 自己按容量（默认 20 MB，远程可调 2–100 MB）与 7 天驱逐。
- **备份与保护类别**：SDK 对目录与每个文件设 `isExcludedFromBackup`，并显式设 `completeUntilFirstUserAuthentication`
  （宿主把默认保护类设成 Complete 也不影响锁屏后台写入）。重启后首次解锁前写不进去的行只计数，不缓存——R-1 登记的例外：
  有会话时义务行记 `write_failed` 墓碑；还没有会话（首次解锁前建不了）时计数，之后以合成 warn `rtv.pre_init_dropped` 上报。
- **SDK 目录被删**：宿主在运行中删掉 SDK 目录（清缓存、退出登录清数据）时，SDK 在下一次换段 / 封段时发现，重新建会话（root 也没了则是新 install），
  留合成 warn `rtv.root_vanished`，期间写不进去的行按 `rtv.pre_init_dropped` 计数上报。请不要这样做：那之前写的行会丢。
- **`log()` 落盘即返回**：每行一次 `write(2)`，不经用户态缓冲；进程被杀 / 崩溃不丢。可从任意线程同步调用。
  `redact` 钩子在落盘前同步执行（configure 之前的行在收编时补过钩子，那时在 SDK 的后台线程上），钩子里调 `log()` 会被忽略，改 `ts` 无效。
- **扩展 / 多进程**：每个进程用不同的 `options.processName`（如 `"share-ext"`），在首次 `configure` 里给出
  （`appGroup` / `processName` 决定目录，只认首次 configure）。出站箱共享，只有持有
  `upload.lock` 的进程上传；活着的会话目录持有 flock，别的进程不会把它当孤儿恢复。
  - **`appGroup` 暂不支持生产**：SDK 在组容器里持有文件锁，app 挂起时仍持有，可能被系统以 `0xdead10cc` 终止。重构另立 ADR 前请不要在上线版本设 `appGroup`。
  - `setEnabled(false)` 的标记多进程共享：别的进程的上传与拉配置在下一次决策时就停，但它的写入要到它自己调用 `setEnabled(false)` 或重启才停。
  - `purgeLocal()` 只保证调用进程：其它进程内存里的 install 与已打开的文件不变，它们之后写出的批按各自信封里的 install 上报（不被服务端隔离）。
- **gzip**：请求体是单成员标准 gzip（zlib windowBits 31），无尾随字节；文件字节即请求体，重试原样重发。
- **网络**：SDK 用自己的 ephemeral `URLSession`，不经宿主的 session / 拦截器；服务端不回 3xx，SDK 也不跟随重定向。
- **换 key**：`configure` 换了 key（或 baseURL）时，鉴权暂停与退避清掉、映射重发、配置缓存按过期处理并立即重拉；旧 key 发出的在途请求回 401 / 403
  不会暂停新 key。出站箱里的旧批照常用新 key 发——**开发机在 staging / 生产之间切换前先 `purgeLocal()` 或卸载重装**，否则旧环境的日志会发到新环境。
- **单元测试宿主**：XCTest 的宿主 app 会跑你的 `AppDelegate` / `App.init`，其中的 `configure` 会用真 key 把测试期间的日志传上去。
  测试 target 里不要注入真 key（例如 key 只在非测试构建的 xcconfig 里给）。
- **前后台**：SDK 首次被触达时起就在记前后台状态（非主线程首次触达时先记「未知」，随后在主线程补读），新会话的 `last_state` 取当时的状态——
  不会把后台启动、后台里建的会话误记成前台（误记会在下次启动合成假的 `rtv.unclean_exit`）。

## os.Logger 项目怎么接

`Retriever` 本体自带 `RetrieverLogger`（不需要额外依赖），方法名与 `os.Logger` 相同：只换构造，每条同时写 os.Logger 和 Retriever。
tag = category，attrs 自动带 `subsystem`；级别 debug → debug、info / notice → info、warning → warn、error → error、fault → fatal；
低于 `Retriever.localLevel` 的行不进 Retriever（os.Logger 照写）。

写系统日志时消息默认 `privacy: .private`（Console.app / sysdiagnose 里显示 `<private>`，与 os.Logger 对插值字符串的默认遮蔽同级）；
消息都是写死文字、不含个人数据的宿主可用 `RetrieverLogger(subsystem:category:publicSystemLog: true)` 打开。Retriever 那一路不受影响。

```swift
import Retriever

// 1. 启动时 configure（key / baseURL 从 Info.plist 读，见下）
let key = Bundle.main.object(forInfoDictionaryKey: "RetrieverKey") as? String ?? ""
let base = (Bundle.main.object(forInfoDictionaryKey: "RetrieverBaseURL") as? String).flatMap(URL.init(string:))
Retriever.configure(key: key, baseURL: base ?? URL(string: "https://logs.revdog.org")!)

// 2. 原来的 Logger(subsystem:category:) 换成 RetrieverLogger，调用处不改
let log = RetrieverLogger(subsystem: "com.example.app", category: "billing")
log.error("purchase failed", attrs: ["sku": .string("pro")], error: err)
```

key 用 xcconfig 注入（与示例 app 一致，不进仓库）：

```
// Config/Retriever.local.xcconfig（gitignored；xcconfig 里 `//` 是注释，URL 写成 https:/$()/host）
RETRIEVER_KEY = lk_live_<app>_<random>_<crc>
RETRIEVER_BASE_URL = https:/$()/logs.revdog.org
```

在 target 的基础 xcconfig 里 `#include? "Retriever.local.xcconfig"`，Info.plist 加两项：
`RetrieverKey` = `$(RETRIEVER_KEY)`、`RetrieverBaseURL` = `$(RETRIEVER_BASE_URL)`。没有本地文件时 key 为空：只写本地不上传。

## 接错 key / 地址时怎么看（0.3.0，ADR 0025）

`configure` 时 SDK 在本地检查 key 与 baseURL，服务端拒绝 key 时也会说出来，都写进**系统日志**：subsystem `org.revdog.retriever`、
category `diagnostics`，消息 `.public`。只出诊断、不拦请求（请求照发，服务端是唯一裁决者）；**SDK 不会因此停写本地**，key / 地址改对后之前的日志照常补传。
消息是写死的英文句子，不含 key 的任何部分。

| code | 级别 | 何时 |
|---|---|---|
| `no_key` | info | key 为空（含去掉空白后为空）：只写本地、永不上传 |
| `key_trimmed` | notice | key 首尾有空白 / 控制字符（CI secret 尾部换行、复制时带的空格），已去掉后再用 |
| `key_malformed` | notice | 不是合法的 Retriever key（格式或末 8 位校验不对），服务端会拒绝 |
| `key_env_mismatch` | notice | `lk_test_` key 配生产地址 `logs.revdog.org`，或 `lk_live_` key 配 staging 地址 `logs-staging.revdog.org` |
| `base_url_invalid` | notice | baseURL 不是带主机的 http(s) URL（例如 `URL(string: "logs.revdog.org")` 漏了 `https://`），上传会一直失败 |
| `key_rejected` | notice | 服务端以 401 / 403 拒绝当前 key，上传进入暂停（1 h 起倍增到 24 h）：`server rejected the key (HTTP 401, reason=…); uploads paused for 60 min; logs are kept locally` |

- 同一（code, key, baseURL）每进程最多一条；`setEnabled(false)` 时照常出（接入时正需要看）。
- key 首尾的空白与控制字符在 `configure` 时去掉后再用（请求头、「参数与上次相同」的判定都用去掉后的值）；baseURL 是 `URL`，不做修剪。
- 怎么看：
  - Xcode 调试时直接出现在控制台。
  - Console.app：左栏选设备 / 模拟器，搜索 `subsystem:org.revdog.retriever`；`no_key` 是 info 级，要打开菜单 Action → Include Info Messages 才显示。
  - 命令行：`log stream --predicate 'subsystem == "org.revdog.retriever"'`（加 `--level info` 才含 `no_key`）；
    模拟器里的 app 用 `xcrun simctl spawn booted log stream --level info --predicate 'subsystem == "org.revdog.retriever"'`。

## 适配器

### swift-log

```swift
import Logging
import RetrieverSwiftLog

LoggingSystem.bootstrap { label in RetrieverLogHandler(label: label) }   // 进程内只能 bootstrap 一次
// 已有 handler 时并联：
// LoggingSystem.bootstrap { MultiplexLogHandler([StreamLogHandler.standardOutput(label: $0), RetrieverLogHandler(label: $0)]) }
```

级别 trace → debug、notice → info、warning → warn、critical → fatal；`tag` = logger label；默认 `logLevel = .info`；
metadata（handler + metadataProvider + 调用处，后者优先）扁平化进 `attrs`：嵌套 dictionary 用 `a.b` 点号键、数组转 JSON 字符串、
stringConvertible 用 description；超过 32 键 / 4 KB 由 SDK 截断并标 `truncated`。`LogEvent.error` 进 `exc`。

### CocoaLumberjack

```swift
import CocoaLumberjackSwift
import RetrieverCocoaLumberjack

asyncLoggingEnabled = false            // 必须：CocoaLumberjackSwift 的全局开关（不是 DDLog 的属性）
DDLog.add(RetrieverDDLogger(), with: .all)
```

**必须关异步分发**：CocoaLumberjack 默认把非 error 行异步交给 logger，开着时 R-1 只从 `RetrieverDDLogger` 回调起算，
DDLog 队列里还没分发的行在进程被杀时会丢（方案 §3.3-7，宪法 §3 登记的例外）。映射：error → error、warning → warn、
info → info、debug / verbose → debug（没有 fatal）；`tag` = `representedObject`（DDLog 的 `tag:` 参数）的字符串描述，否则文件名；
`attrs` = `file` / `function` / `line`。

## 示例 app（`Example/`）

```bash
cd sdk/ios/Example
./gen-local-xcconfig.sh          # 从仓库根 .env 的 EXAMPLE_KEY_STAGING 生成 Retriever.local.xcconfig（gitignored，不打印 key）
xcodegen generate                # 生成 RetrieverExample.xcodeproj（gitignored）
open RetrieverExample.xcodeproj  # 选真机运行（自动签名，team R22CUP27Y4）
```

没有 `Retriever.local.xcconfig` 时 key 为空：只写本地不上传。baseURL 固定 `https://logs-staging.revdog.org`（staging 只收 `lk_test_` key）。
界面显示 installId / supportCode / 出站箱待传数 / 生效级别；按钮演示 `Retriever.log`、swift-log、DDLog 三种写法，以及 flush、setUser、崩溃恢复、5000 行压测。
启动参数 `--scenario <name>` 跑验收场景：`error`、`bulk`、`user`、`flush`、`crash`，以及 0.3.0 的 `preconfigure`（configure 之前各级别 log 若干、
再 configure，末尾 warn `scenario preconfigure done`）与 `preconfigure_kill`（log 后在 configure 之前自杀；下次启动后作为独立会话上传）。
只有这两个场景把 `configure` 往后推，其余场景照旧 configure 最先。
命令行只编译不签名：`xcodebuild -project Example/RetrieverExample.xcodeproj -scheme RetrieverExample -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`。

## SDK 合成行（`synthetic: true`，不经 `redact`）

| tag | 级别 | 何时 |
|---|---|---|
| `rtv.flush` | error | `flush()` 的标记行 |
| `rtv.unclean_exit` | error | 恢复时：上次进程在前台结束、没收尾 |
| `rtv.install_repaired` / `rtv.install_reset` | warn | install.json 损坏时修复 / 重建 |
| `rtv.pre_init_dropped` | warn | 有没写成的行（pre 文件满 / 写不进、还没有会话）：attrs `count` / `error_count` / `first_ts` / `last_ts` |
| `rtv.root_vanished` | warn | SDK 目录在运行中被删、已重新建会话 |
| `rtv.reconfigure_ignored` | warn | 之后的 `configure` 改了 `processName` / `appGroup`（attrs `field`），已忽略 |

## 协议备注（与服务端 / 另两端对齐）

- `batch_id`：primary = UUIDv5(ns, `<install>:<session>:primary:<oseq_from>`)；backfill 每段一批 = `…:backfill:<seg_no>`；
  **单段超 768 KB 按 seq 切多批时** = UUIDv5(ns, `<install>:<session>:backfill:<seg_no>:<seq_from>`)（三段 name）；
  **413 切分出的半批** = UUIDv5(ns, `<install>:<session>:primary:<oseq_from>:<oseq_to>`)（install 取原批信封，ADR 0019），全部半批写成后才删原批。
- 请求头 `X-Rtv-Install` 取批自身信封里的 install_id；`mapping.json` 只在响应 `status == "stored"` 且批属于当前 install 时更新。
- 终态只为有义务行的会话写；每批按文件顺序带最旧的 20 条终态 / 100 条墓碑，不合并、不截断（不再发 `closed_sessions_dropped`）；
  `sessions.jsonl` / `drops.jsonl` 各自上限 1000 条，墓碑超限先无损合并（同会话、同 reason、区间相接），仍超出删最旧的。
- backfill 回传 RETAINED 段里的**全部非义务行**，可能与已作为 ctx 上传的行重复，读侧按 `(session_id, seq)` 去重。
- 本地状态文件比方案 §3.2 多几处：根目录 `config.json`（远程配置缓存）、`cursor.json.closed_ms`（旧会话已结束标记）、
  `backoff.json.last_ack_ms`（墓碑 `last_ack_age_ms` 跨启动）、`meta.json.install_id`（install 身份的冗余副本：install.json 损坏时据此修复、
  不换 id；0.1.x 的 meta 没有这个键，照读）；root 同级的 `<root>.disabled`（禁用标记）与 `<root>.purge-<uuid>`（清空时先改名再删，残留在启动时清掉）。
- 远程配置请求头另带 `X-Rtv-Local-Cap-Bytes`（宿主 `localCapBytes`）。`setUser` 值变化即按新身份重拉配置；身份变化的那一刻缓存按过期处理
  （放大型字段立即回落），请求发出后身份（install / user / 四项宿主默认 / key 指纹 / baseURL）又变了的响应丢弃并重拉。
- 配置响应的 `from_host`（ADR 0022）：列出的宿主型字段取的是请求头里的宿主默认，SDK 缓存时记下它，生效时这些字段永远取**当前**宿主默认；
  没有该键（旧服务端 / 0.2.x 的缓存）= 空集。宿主改 `uploadLevel` 等立即生效，不依赖缓存新旧。
- 0.3.0 新增的本地状态：默认 root 下 `pre/<uuid>.jsonl`（configure 之前的行）；`meta.json` 可选键 `pre`（收编中，提交后清掉）；
  `config.json` 加 `key_fp` / `base_url` / `from_host`，`backoff.json` / `mapping.json` 加 `key_fp` / `base_url`（key 指纹 = sha256(key) 前 16 位十六进制）。
  旧版本写的文件没有这些键照读：指纹缺失视为与当前 key 相同并补写（升级不清退避、不重发映射、不丢配置缓存）。

## 开发

```bash
swift build && swift build -c release
swift test        # golden 向量、跨语言信封校验（需仓库根 npm install）、真杀进程（RetrieverKillHelper）、两个适配器
```

## 脱敏（宿主建议）

日志在落盘前经过 `Options.redact: (LogLine) -> LogLine?`（返回 nil = 丢弃该行）。宿主自己的 URL、交易号、用户标识往往会出现在第三方 SDK 的错误文本里，建议在这里统一掩码，例如把 `/v1/subscribers/<id>` 与 `tx=<id>` 替换成 `<masked>`（bff iOS 的做法）。Retriever 服务端不做二次脱敏，落盘的就是上传的。

隐私清单（`PrivacyInfo.xcprivacy`，随包分发）声明收集：Device ID（install_id）、User ID（`setUser` 的值）、Crash Data、Other Diagnostic Data；
均关联用户、不用于跟踪，用途 App Functionality。宿主在 App Store Connect 填隐私标签时同步这四项。
