# R2BOX

原生 macOS 的 S3 / Cloudflare R2 文件管理器。Swift 6 + SwiftUI，无 Electron / WebView。

核心体验：

```
R2 → config.yaml → 双击
        ↓ 下载到本地工作区
        ↓ NSWorkspace 用默认编辑器打开
        ↓ 正常编辑、⌘S
        ↓ FSEvents 检测本地变化
        ↓ 自动上传（If-Match ETag 条件写入）
        ↓ 状态栏 ✓ 已同步
```

⌘S 正常保存即自动同步；只有远程 ETag 与下载基线不一致（他人改过远程）时才弹冲突对话框。

## 当前状态：Phase 2（真实 S3/R2 已接入）

- **真实连接**：Endpoint 含 `demo.`（或 Access Key 为空）的连接使用内置 Mock 演示数据；
  其余 Endpoint 走 `AWSS3Service` —— 手写 SigV4 签名（经 AWS 官方测试向量校验）+ URLSession 流式传输，
  Path-Style / Virtual-Host 寻址、R2 `region=auto` 均支持。UI 与同步引擎零改动。
- **Mock 连接**：内存数据 + 模拟延迟/断网 + 分块流式传输，用于演示冲突与断网续传。

### 已实现

| 功能 | 状态 |
|---|---|
| Finder 风格 UI（NavigationSplitView / Table / Toolbar / Context Menu / SF Symbols） | ✅ |
| Sidebar：多连接 + Bucket 列表 + 面包屑 | ✅ |
| 双击下载到本地工作区并用默认 App 打开（NSWorkspace） | ✅ |
| 空格 Quick Look 预览 | ✅ |
| 监听本地文件变化自动上传（FSEvents + 防抖） | ✅ |
| 上传前 ETag 条件写入（If-Match / 412 Precondition Failed） | ✅ |
| 冲突三选项：覆盖远程 / 重新加载远程 / 保留本地 | ✅ |
| 断网保留本地修改，恢复后自动续传（重试队列 + 退避） | ✅ |
| 上传/下载进度（行内 + 状态栏） | ✅ |
| 拖拽上传 / 上传按钮（NSOpenPanel 多选） | ✅ |
| 新建文件夹 / 重命名 / 删除（文件夹递归） | ✅ |
| 大文件流式分块传输（不整载内存） | ✅ |
| Secret Key 存 macOS Keychain（每次请求按需读取，不常驻内存） | ✅ |
| 连接配置持久化（Application Support/R2BOX/connections.json） | ✅ |
| 真实 S3/R2：SigV4 签名（官方向量校验）、ListObjectsV2 自动翻页、批量删除（≤900/批）、x-amz-copy-source 重命名 | ✅ |
| NWPathMonitor：系统网络恢复后自动续传重试队列 | ✅ |

### 暂未实现（按约定排除）

- Finder 虚拟磁盘 / File System Extension
- Multipart 上传（单次 PUT 上限 5GB，超出需分片）、Presigned URL 复制、并发传输队列上限控制
- 多选批量操作、服务端分页（`list-objects-v2` continuation token）、multipart 上传

## 构建与运行

需要 Swift 6 工具链（Xcode 或 Command Line Tools 均可）。

```bash
# 跑校验器（13 项断言：Mock S3 行为、同步引擎全链路、Keychain）
swift run R2BOXChecker

# 构建 Debug 包并启动
scripts/run.sh --open

# Release 包
scripts/run.sh --release --open

# 进程内端到端自检（真实 App 进程内跑完整链路，结果输出到 stderr）
./build/R2BOX.app/Contents/MacOS/R2BOX --selftest
```

也可以直接 `swift run R2BOXApp`（无 bundle 启动），或用 Xcode 打开 `Package.swift` 运行 `R2BOXApp` target。

## 演示冲突 / 断网（菜单「同步」）

1. 双击 `config.yaml` → 在编辑器里改一行 → ⌘S → 状态栏出现「✓ 已同步」
2. 菜单「同步 → 在远程修改选中文件（模拟冲突）」→ 再改一次本地文件并保存
   → 弹出冲突对话框（覆盖远程 / 重新加载远程 / 保留本地）
3. 菜单「同步 → 模拟网络中断」→ 再保存一次 → 状态栏红色「网络中断 — 本地修改已保留」
   → 关掉断网模拟 → 自动续传完成

## 架构

```
Sources/
├── R2BOXCore/                 # 领域层（无 UI 依赖）
│   ├── Models.swift           #   Connection / BucketInfo / ObjectEntry / S3Error
│   ├── S3Service.swift        #   S3/R2 抽象协议（流式约定 + If-Match 语义）+ 工厂
│   ├── SigV4.swift            #   AWS Signature V4 纯函数实现
│   ├── AWSS3Service.swift     #   真实 S3/R2 实现（actor，分页/批量删除/流式）
│   ├── S3XML.swift            #   S3 XML 响应解析 + 错误映射
│   ├── MockS3Service.swift    #   Mock 实现（actor，延迟/断网/远程修改模拟）
│   ├── MockDataStore.swift    #   Mock 数据（演示 Bucket / 大文件 / 文本配置）
│   ├── KeychainStore.swift    #   Keychain 读写 Secret
│   ├── ConnectionStore.swift  #   连接配置 JSON 持久化
│   └── Formatting.swift       #   大小/时间/图标格式化
├── R2BOXSync/                 # 同步引擎层
│   ├── Workspace.swift        #   本地工作区路径管理（~/Library/.../R2BOX/workspace）
│   ├── WorkspaceWatcher.swift #   FSEvents 目录监听
│   ├── Debouncer.swift        #   防抖（合并编辑器高频写入）
│   ├── MetadataStore.swift    #   跟踪清单持久化（重启恢复 baseETag）
│   └── SyncEngine.swift       #   actor：自动上传 / 冲突决策 / 断网重试
├── R2BOX/                     # SwiftUI 应用
│   ├── R2BOXApp.swift         #   @main + 菜单命令（⌘S 立即同步等）
│   ├── AppState.swift         #   @Observable 状态机 + ConnectionManager
│   ├── SelfTest.swift         #   --selftest 进程内端到端自检
│   └── Views/                 #   ContentView / Sidebar / Browser / FileList / Sheets
└── Tests/R2BOXChecker/        # 无 XCTest 依赖的校验器（CLT 环境可跑）
```

### 关键设计

- **S3Service 协议**：`S3ServiceFactory.service(for:)` 按端点在 Mock 与 `AWSS3Service` 间分发。
  真实实现采用手写 SigV4 + URLSession（零第三方依赖），签名器用 AWS 官方测试向量（get-vanilla、derive signing key）校验。
- **冲突检测**：上传携带下载时的 `baseETag`（If-Match）。远程不匹配 → Mock 抛 `.preconditionFailed`（真实 S3 返回 412）→ `SyncEngine.resolveConflict` 经 `conflictHandler` 弹窗等用户选择，绝不静默覆盖。
- **FSEvents → 防抖 → 上传**：编辑器原子保存会产生高频事件，按文件 600ms 防抖；上传中再次变化会标脏并在完成后补一轮上传。
- **网络恢复**：`NWPathMonitor` 回到 satisfied 时清空失败标记并续传重试队列（Mock 断网模拟仍走菜单开关）。
- **Swift 6 严格并发**：引擎为 actor；UI 状态镜像到 `@MainActor @Observable` 的 `AppState`，事件跨越线程边界时显式跳转。
- **本地删除不联动远程删除**：本地文件被删仅停止跟踪（防误删），远程删除走 UI 显式操作。

## 已知限制 / 后续路线

1. Multipart 上传（当前单次 PUT，≤5GB 已够配置文件场景）
2. Presigned URL 复制、服务端加密 / StorageClass 展示
3. 并发传输队列上限控制与暂停/恢复
4. 使用真实连接前请确认凭据有效；Keychain 授权弹窗按一次「始终允许」即可
