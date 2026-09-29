# Retriever iOS 传输层（`sdk/ios`）

Swift 6 SPM 包，零第三方依赖（gzip 用系统 zlib）。iOS 15+ / macOS 12+。规格：`docs/plan/system-design.md` §3；不变式：`docs/architecture.md` §2。

## 接入（5 行）

```swift
import Retriever

// application(_:didFinishLaunchingWithOptions:) 里、第一条日志之前
var o = Options(); o.uploadLevel = .warn          // 可选 .info / .debug（ADR 0004）
Retriever.configure(key: "lk_live_<app>_…", options: o)
Retriever.setUser(currentUserId)                    // 登录 / 登出时再调；nil = 未登录
Retriever.log(.error, "purchase failed", tag: "billing", attrs: ["code": .number(7)], error: err)
```

「上报问题」按钮：`let r = await Retriever.flush()`（视同一次 error，带上下文；`.stored` = 已被服务端确认）。
用户撤回同意：`Retriever.setEnabled(false)`（不写不传）；清空本地：`Retriever.purgeLocal()`。客服短码：`Retriever.supportCode`。

## 宿主必须知道的纪律

- **目录**：`Library/Application Support/<bundle-id>.retriever/`（`appGroup` 非空时为组容器里的 `<group>.retriever/`）。
  不要把它挪进 Caches / tmp，也不要自行清理；SDK 自己按容量（默认 20 MB）与 7 天驱逐。
- **备份与保护类别**：SDK 对目录与每个文件设 `isExcludedFromBackup`，并显式设
  `completeUntilFirstUserAuthentication`（宿主把默认保护类设成 Complete 也不影响锁屏后台写入）。
  重启后首次解锁前写不进去的行只计数（`write_failed` 墓碑），不缓存——这是 R-1 登记的例外。
- **`log()` 落盘即返回**：每行一次 `write(2)`，不经用户态缓冲；进程被杀 / 崩溃不丢。可从任意线程同步调用。
  `redact` 钩子在落盘前同步执行，钩子里调 `log()` 会被忽略。
- **扩展 / 多进程**：每个进程用不同的 `options.processName`（例如 `"share-ext"`），并在第一条日志之前 `configure`
  （`appGroup` / `processName` 决定目录，懒初始化后再改会切换到新目录）。出站箱共享，只有持有 `upload.lock` 的进程上传。
- **gzip**：请求体是单成员标准 gzip（zlib windowBits 31），无尾随字节；文件字节即请求体，重试原样重发。
- **网络**：SDK 用自己的 ephemeral `URLSession`，不经宿主的 session / 拦截器；服务端不回 3xx，SDK 也不跟随重定向。
- **CocoaLumberjack / swift-log 适配器**：下一切片提供（CocoaLumberjack 需宿主关 `asyncLoggingEnabled`，否则异步窗口内的行不在 R-1 之内）。

## 开发

```bash
swift build && swift build -c release
swift test        # 含 golden 向量、跨语言信封校验（需仓库根 npm install）、真杀进程（RetrieverKillHelper）
```
