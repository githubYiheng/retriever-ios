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
.package(url: "https://github.com/githubYiheng/retriever-ios.git", from: "0.2.0"),
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

// application(_:didFinishLaunchingWithOptions:) 里、第一条日志之前
var o = Options(); o.uploadLevel = .warn          // 可选 .info / .debug（ADR 0004）
Retriever.configure(key: "lk_live_<app>_…", options: o)
Retriever.setUser(currentUserId)                    // 登录 / 登出时再调；nil = 未登录
Retriever.log(.error, "purchase failed", tag: "billing", attrs: ["code": .number(7)], error: err)
```

- 「上报问题」：`let r = await Retriever.flush()`。它向当前段追加一条合成行（`error`、`tag: "rtv.flush"`、`synthetic: true`，
  无视上传级别一定上传），立即封段并排空；该批 15 s 内被服务端确认 → `.stored`，否则 `.pending("offline" | "backoff" | "paused" | "timeout")`
  （`setEnabled(false)` 时 `.pending("disabled")`）。`flush(includeContext: false)` 时该批不带上下文。
- 用户撤回同意：`Retriever.setEnabled(false)`——不写、不传、不拉配置，**落盘、跨重启有效**，直到 `setEnabled(true)`。
  状态记在 root 同级的空标记文件 `<root>.disabled`（清空本地不会带走它）；`configure` 之前调用也生效；`Retriever.isEnabled` 读当前值。
  标记写失败（磁盘满、首次解锁前）时本进程照样禁用、稍后重试；在写成之前进程就死的话下次启动是启用的——撤回同意的宿主请在每次启动、
  `configure` 之前再调一次 `setEnabled(false)`（幂等）。在途的那一个请求不取消（数据是同意期内采集的）。
  不要把它当「临时暂停」用：重启不会恢复。
- 清空本地：`Retriever.purgeLocal()`（新 install_id）。**不阻塞调用线程**：返回时清空尚未完成，`installId` 要在
  `Retriever.purgeLocal { … }` 的完成回调（后台线程）里才是新值；返回到回调之间写的行随旧状态一起删除。撤回同意 = `setEnabled(false)` + `purgeLocal()`。
- 客服短码：`Retriever.supportCode`。生效级别（远程配置钳制后）：`Retriever.uploadLevel` / `Retriever.localLevel`，适配器用来早过滤。
- 整数 attrs（订单号、雪花 id 等）用 `.int(_:)`：`attrs: ["order": .int(Int64(orderId))]`。|v| ≤ 2^53 − 1 输出 JSON 数字，
  超出输出十进制字符串（Double 表示不了，否则会被静默改成别的数）。
- `fatal`（含 `RetrieverLogger.fault`、swift-log `critical`）：行在返回前已落盘，封段与物化在后台进行，**不阻塞调用线程**；
  进程随后死掉，下次启动会恢复并上报同一批。只能在 ObjC / Swift 异常处理路径里调，**不能在 signal handler 里调**（不是 async-signal-safe）。

## 宿主必须知道的纪律

- **目录**：`Library/Application Support/<bundle-id>.retriever/`（`appGroup` 非空时为组容器里的 `<group>.retriever/`）。
  不要挪进 Caches / tmp，也不要自行清理；SDK 自己按容量（默认 20 MB，远程可调 2–100 MB）与 7 天驱逐。
- **备份与保护类别**：SDK 对目录与每个文件设 `isExcludedFromBackup`，并显式设 `completeUntilFirstUserAuthentication`
  （宿主把默认保护类设成 Complete 也不影响锁屏后台写入）。重启后首次解锁前写不进去的行只计数（`write_failed` 墓碑），不缓存——R-1 登记的例外。
- **`log()` 落盘即返回**：每行一次 `write(2)`，不经用户态缓冲；进程被杀 / 崩溃不丢。可从任意线程同步调用。
  `redact` 钩子在落盘前同步执行，钩子里调 `log()` 会被忽略。
- **扩展 / 多进程**：每个进程用不同的 `options.processName`（如 `"share-ext"`），并在第一条日志之前 `configure`
  （`appGroup` / `processName` 决定目录，懒初始化后再改会切换到新目录；切换不阻塞，旧目录的收尾在后台完成）。出站箱共享，只有持有
  `upload.lock` 的进程上传；活着的会话目录持有 flock，别的进程不会把它当孤儿恢复。
  - **`appGroup` 暂不支持生产**：SDK 在组容器里持有文件锁，app 挂起时仍持有，可能被系统以 `0xdead10cc` 终止。重构另立 ADR 前请不要在上线版本设 `appGroup`。
  - `setEnabled(false)` 的标记多进程共享：别的进程的上传与拉配置在下一次决策时就停，但它的写入要到它自己调用 `setEnabled(false)` 或重启才停。
  - `purgeLocal()` 只保证调用进程：其它进程内存里的 install 与已打开的文件不变，它们之后写出的批按各自信封里的 install 上报（不被服务端隔离）。
- **gzip**：请求体是单成员标准 gzip（zlib windowBits 31），无尾随字节；文件字节即请求体，重试原样重发。
- **网络**：SDK 用自己的 ephemeral `URLSession`，不经宿主的 session / 拦截器；服务端不回 3xx，SDK 也不跟随重定向。

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
命令行只编译不签名：`xcodebuild -project Example/RetrieverExample.xcodeproj -scheme RetrieverExample -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`。

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
  （放大型字段立即回落），请求发出后身份又变了的响应丢弃。

## 开发

```bash
swift build && swift build -c release
swift test        # golden 向量、跨语言信封校验（需仓库根 npm install）、真杀进程（RetrieverKillHelper）、两个适配器
```

## 脱敏（宿主建议）

日志在落盘前经过 `Options.redact: (LogLine) -> LogLine?`（返回 nil = 丢弃该行）。宿主自己的 URL、交易号、用户标识往往会出现在第三方 SDK 的错误文本里，建议在这里统一掩码，例如把 `/v1/subscribers/<id>` 与 `tx=<id>` 替换成 `<masked>`（bff iOS 的做法）。Retriever 服务端不做二次脱敏，落盘的就是上传的。

隐私清单（`PrivacyInfo.xcprivacy`，随包分发）声明收集：Device ID（install_id）、User ID（`setUser` 的值）、Crash Data、Other Diagnostic Data；
均关联用户、不用于跟踪，用途 App Functionality。宿主在 App Store Connect 填隐私标签时同步这四项。
