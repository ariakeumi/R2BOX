import SwiftUI
import R2BOXCore
import R2BOXSync
import UniformTypeIdentifiers

struct BrowserView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            switch state.phase {
            case .idle:
                ContentUnavailableView("选择连接", systemImage: "externaldrive.badge.icloud")
            case .loading:
                ProgressView("正在连接…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("连接失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") {
                        if let conn = state.connection {
                            state.connect(to: conn)
                        }
                    }
                }
            case .loaded:
                browserContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var browserContent: some View {
        VStack(spacing: 0) {
            BreadcrumbView()
            Divider()
            FileListView()
            Divider()
            StatusBarView()
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: Binding(
            get: { state.renameTarget != nil },
            set: { if !$0 { state.renameTarget = nil } }
        )) {
            RenameSheet()
        }
        .sheet(isPresented: Binding(
            get: { state.folderTarget != nil },
            set: { if !$0 { state.folderTarget = nil } }
        )) {
            NewFolderSheet()
        }
        .confirmationDialog(
            "删除所选项目？",
            isPresented: Binding(
                get: { !state.deleteTargets.isEmpty },
                set: { if !$0 { state.deleteTargets = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                let targets = state.deleteTargets
                state.deleteTargets = []
                Task { await state.delete(targets) }
            }
            Button("取消", role: .cancel) { state.deleteTargets = [] }
        } message: {
            Text("将从 Bucket 中删除 \(state.deleteTargets.count) 个项目，且不可撤销。")
        }
        .fileImporter(
            isPresented: uploadSheetBinding,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await state.uploadFileURLs(urls) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await state.uploadFileURLs(urls) }
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .foregroundStyle(.tint)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(8)
                    .overlay {
                        Label("松开以上传到当前文件夹", systemImage: "arrow.up.doc")
                            .font(.title3.bold())
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    @State private var dropTargeted = false
    private var uploadSheetBinding: Binding<Bool> {
        Binding(get: { false }, set: { _ in }) // 占位，用 toolbar 按钮直接弹 NSSavePanel/openPanel
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                state.navigateUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(state.prefix.isEmpty)
            .help("上一级")

            Button {
                state.folderTarget = state.prefix
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("新建文件夹")

            Button {
                openUploadPanel()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("上传文件")

            Button {
                Task { await state.refreshCurrent() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("刷新")
        }
    }

    /// 系统打开面板选择要上传的文件
    private func openUploadPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "选择要上传到当前文件夹的文件"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { await state.uploadFileURLs(urls) }
        }
    }
}
