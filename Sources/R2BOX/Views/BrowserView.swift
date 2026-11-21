import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @Environment(AppState.self) private var state
    @State private var dropTargeted = false
    @State private var choosingFiles = false

    private var ready: Bool {
        state.phase == .loaded && state.selectedBucket != nil
    }

    private var title: String {
        if !state.prefix.isEmpty, let folder = state.breadcrumbParts.last { return folder.name }
        return state.selectedBucket ?? state.connection?.name ?? "R2BOX"
    }

    private var subtitle: String {
        if !state.prefix.isEmpty { return state.selectedBucket ?? "" }
        guard let bucket = state.selectedBucket, let connection = state.connection,
              bucket != connection.name else { return "" }
        return connection.name
    }

    var body: some View {
        Group {
            switch state.phase {
            case .idle:
                if ConnectionManager.shared.connections.isEmpty {
                    ContentUnavailableView {
                        Label("连接储存桶", systemImage: "externaldrive.badge.icloud")
                    } description: {
                        Text("添加 S3 兼容储存的连接，即可浏览和同步文件。")
                    } actions: {
                        Button("新建连接…") { state.presentConnectionSheet() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView("选择连接", systemImage: "externaldrive.badge.icloud")
                }
            case .loading:
                ProgressView(state.selectedBucket == nil ? "正在连接…" : "正在载入文件…")
            case .failed(let message):
                ContentUnavailableView {
                    Label("无法载入储存桶", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                        .textSelection(.enabled)
                } actions: {
                    Button("重试") { state.retryBrowsing() }
                }
            case .loaded:
                if ready {
                    browserContent
                } else {
                    ContentUnavailableView("没有可用的储存桶", systemImage: "archivebox")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .sheet(item: Bindable(state).renameTarget) { entry in
            RenameSheet(entry: entry)
        }
        .sheet(isPresented: Binding(
            get: { state.folderTarget != nil },
            set: { if !$0 { state.folderTarget = nil } }
        )) {
            NewFolderSheet()
        }
        .alert(
            "删除所选项目？",
            isPresented: Binding(
                get: { !state.deleteTargets.isEmpty },
                set: { if !$0 { state.deleteTargets = [] } }
            ),
            presenting: state.deleteTargets
        ) { targets in
            Button("删除", role: .destructive) {
                state.deleteTargets = []
                Task { await state.delete(targets) }
            }
            Button("取消", role: .cancel) {}
        } message: { targets in
            Text("将从储存桶中永久删除 \(targets.count) 个项目。")
        }
    }

    private var browserContent: some View {
        VStack(spacing: 0) {
            FileListView(upload: { choosingFiles = true })
            Divider()
            BrowserStatusBar()
        }
        .fileImporter(
            isPresented: $choosingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
                    defer { for url in accessed { url.stopAccessingSecurityScopedResource() } }
                    await state.uploadFileURLs(urls)
                }
            case .failure(let error):
                state.errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { await state.uploadFileURLs(files) }
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.thinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    }
                    .overlay {
                        Label("松开以上传到当前文件夹", systemImage: "arrow.up.doc")
                            .font(.headline)
                    }
                    .padding(8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: state.navigateUp) {
                Label("上一级", systemImage: "chevron.up")
            }
            .disabled(state.prefix.isEmpty)
            .help("返回上级文件夹")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                state.folderTarget = state.prefix
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }
            .disabled(!ready)
            .help("新建文件夹")
        }

        if #available(macOS 27, *) {
            ToolbarItem(placement: .primaryAction) { uploadButton }
                .visibilityPriority(.high)
        } else {
            ToolbarItem(placement: .primaryAction) { uploadButton }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await state.refreshCurrent() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!ready || state.directoryBusy)
            .help("刷新当前文件夹")
        }
    }

    private var uploadButton: some View {
        Button {
            choosingFiles = true
        } label: {
            Label("上传文件", systemImage: "square.and.arrow.up")
        }
        .disabled(!ready)
        .help("上传文件")
    }
}
