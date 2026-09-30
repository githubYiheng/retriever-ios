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
.package(url: "https://github.com/githubYiheng/retriever-ios.git", from: "0.1.0"),
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
- 用户撤回同意：`Retriever.setEnabled(false)`（不写不传）；清空本地：`Retriever.purgeLocal()`；客服短码：`Retriever.supportCode`。
- 生效级别（远程配置钳制后）：`Retriever.uploadLevel` / `Retriever.localLevel`，适配器用来早过滤。

## 宿主必须知道的纪律

- **目录**：`Library/Application Support/<bundle-id>.retriever/`（`appGroup` 非空时为组容器里的 `<group>.retriever/`）。
  不要挪进 Caches / tmp，也不要自行清理；SDK 自己按容量（默认 20 MB，远程可调 2–100 MB）与 7 天驱逐。
- **备份与保护类别**：SDK 对目录与每个文件设 `isExcludedFromBackup`，并显式设 `completeUntilFirstUserAuthentication`
  （宿主把默认保护类设成 Complete 也不影响锁屏后台写入）。重启后首次解锁前写不进去的行只计数（`write_failed` 墓碑），不缓存——R-1 登记的例外。
- **`log()` 落盘即返回**：每行一次 `write(2)`，不经用户态缓冲；进程被杀 / 崩溃不丢。可从任意线程同步调用。
  `redact` 钩子在落盘前同步执行，钩子里调 `log()` 会被忽略。
- **扩展 / 多进程**：每个进程用不同的 `options.processName`（如 `"share-ext"`），并在第一条日志之前 `configure`
  （`appGroup` / `processName` 决定目录，懒初始化后再改会切换到新目录）。出站箱共享，只有持有 `upload.lock` 的进程上传；
  活着的会话目录持有 flock，别的进程不会把它当孤儿恢复。
- **gzip**：请求体是单成员标准 gzip（zlib windowBits 31），无尾随字节；文件字节即请求体，重试原样重发。
- **网络**：SDK 用自己的 ephemeral `URLSession`，不经宿主的 session / 拦截器；服务端不回 3xx，SDK 也不跟随重定向。

## os.Logger 项目怎么接

`Retriever` 本体自带 `RetrieverLogger`（不需要额外依赖），方法名与 `os.Logger` 相同：只换构造，每条同时写 os.Logger
（`privacy: .public`）和 Retriever。tag = category，attrs 自动带 `subsystem`；级别 debug → debug、info / notice → info、
warning → warn、error → error、fault → fatal；低于 `Retriever.localLevel` 的行不进 Retriever（os.Logger 照写）。

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
  **单段超 768 KB 按 seq 切多批时** = UUIDv5(ns, `<install>:<session>:backfill:<seg_no>:<seq_from>`)（三段 name）。
- backfill 回传 RETAINED 段里的**全部非义务行**，可能与已作为 ctx 上传的行重复，读侧按 `(session_id, seq)` 去重。
- 本地状态文件比方案 §3.2 多三处：根目录 `config.json`（远程配置缓存）、`cursor.json.closed_ms`（旧会话已结束标记）、
  `backoff.json.last_ack_ms`（墓碑 `last_ack_age_ms` 跨启动）。
- 远程配置请求头另带 `X-Rtv-Local-Cap-Bytes`（宿主 `localCapBytes`）。

## 开发

```bash
swift build && swift build -c release
swift test        # golden 向量、跨语言信封校验（需仓库根 npm install）、真杀进程（RetrieverKillHelper）、两个适配器
```

## 脱敏（宿主建议）

日志在落盘前经过 `Options.redact: (LogLine) -> LogLine?`（返回 nil = 丢弃该行）。宿主自己的 URL、交易号、用户标识往往会出现在第三方 SDK 的错误文本里，建议在这里统一掩码，例如把 `/v1/subscribers/<id>` 与 `tx=<id>` 替换成 `<masked>`（bff iOS 的做法）。Retriever 服务端不做二次脱敏，落盘的就是上传的。
