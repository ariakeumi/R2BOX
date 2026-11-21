# R2BOX

原生 macOS 的 S3 兼容存储文件管理器（Cloudflare R2 / Backblaze B2 / 群晖 C2 等）。Swift 6 + SwiftUI，无 Electron、无 WebView。

核心体验：**双击文件 → 下载 → 默认编辑器打开 → ⌘S 保存 → 自动上传回远端**。像编辑本地文件一样编辑云端文件。

## 功能

- 多连接管理，每个连接绑定一个储存桶；Secret Key 存 macOS 钥匙串
- 双击打开、空格 Quick Look 预览、上传 / 下载 / 删除 / 重命名 / 新建文件夹、拖拽上传
- ⌘S 自动同步：FSEvents 监听本地修改，防抖后自动上传（大文件流式传输，不占内存）
- 冲突保护：上传带 If-Match 条件写入，远程被他人修改时弹窗选择（覆盖 / 重新加载 / 保留本地），绝不静默覆盖
- 断网容错：网络中断时保留本地修改，恢复后自动续传
- 下载原子写入（临时文件 + rename），杜绝空文件窗口误上传

## 快捷键

| 按键 | 作用 |
|---|---|
| ⌘1 ~ ⌘9 | 切换侧边栏连接（一个连接 = 一个储存桶） |
| ↑ / ↓ | 移动当前侧栏或文件表格的选中项 |
| Enter | 打开文件 / 进入文件夹 |
| 空格 | Quick Look 预览 |
| ⌘S | 立即同步选中文件 |
| ⌘O | 在默认编辑器中打开 |
| ⌘↑ | 返回上级文件夹 |
| ⇧⌘N | 新建连接 |

## 连接配置

| 参数 | 说明 |
|---|---|
| Endpoint | R2：`https://<account_id>.r2.cloudflarestorage.com`<br>B2：`https://s3.<region>.backblazeb2.com`<br>群晖 C2：`https://<id>.s3.synologyc2.net` |
| Region | R2 填 `auto`，其他按服务商给出的区域 |
| 储存桶 | 留空列出全部；填写后只显示该桶（也兼容仅授权单桶的 API Token） |
| Path-Style | R2 / B2 / C2 均建议开启 |

## 构建运行

运行需要 macOS 14+。构建请使用包含 macOS 27 SDK 的 Xcode 27 或 Command Line Tools。

```bash
./scripts/run.sh --release --open   # 构建 R2BOX.app 并打开
swift run R2BOXChecker              # 运行校验套件
.build/release/R2BOXApp --selftest  # 进程内端到端自检
swift scripts/make_icon.swift <dir> # 重新生成应用图标
```

## 项目结构

```
Sources/
├── R2BOXCore/    # 领域层：模型、SigV4 签名、S3 XML、AWS 实现、Mock、Keychain
├── R2BOXSync/    # 同步引擎：FSEvents 监听、上传队列、冲突、断网重试、工作区
└── R2BOX/        # SwiftUI 应用（侧栏、文件列表、表单、键盘导航、自检）
Tests/R2BOXChecker/  # 自研断言框架（CLT 环境无 XCTest）：签名向量、同步、冲突、回归
scripts/run.sh       # 打包 R2BOX.app（Info.plist / 图标 / 签名）
```

## 数据位置

- 配置与本地工作区：`~/Library/Application Support/R2BOX/`
  - `connections.json` 保存连接配置。每个连接在 `workspace/.connections/<连接 ID>/<连接配置指纹>/` 下保存本地缓存和 `.r2box/tracked.json` 同步基线。
  - 升级前位于 `workspace/<bucket>/<key>` 的副本会原地保留。若其中有未上传的修改，请在对应连接中打开文件，核对后再将旧修改复制到新的本地副本。
- Secret Access Key：macOS 钥匙串（不落盘、不进配置文件）

## License

MIT
