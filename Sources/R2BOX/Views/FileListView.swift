import SwiftUI
import R2BOXCore
import R2BOXSync

struct FileListView: View {
    @Environment(AppState.self) private var state
    @State private var sortOrder = [KeyPathComparator(\Row.name, comparator: .localizedStandard)]
    @FocusState private var tableFocused: Bool
    let upload: () -> Void

    private struct Row: Identifiable {
        let id: String
        let name: String
        let key: String
        let entry: ObjectEntry?

        var isFolder: Bool { entry == nil }
        var size: Int64 { entry?.size ?? 0 }
        var modified: Date { entry?.lastModified ?? .distantPast }

        init(folder prefix: String) {
            id = "dir:" + prefix
            key = prefix
            name = String(prefix.dropLast()).components(separatedBy: "/").last ?? prefix
            entry = nil
        }

        init(object: ObjectEntry) {
            id = "obj:" + object.key
            key = object.key
            name = object.fileName
            entry = object
        }

        var actionEntry: ObjectEntry {
            entry ?? ObjectEntry(key: key, size: 0, lastModified: Date(), etag: "")
        }
    }

    var body: some View {
        if state.folders.isEmpty && state.objects.isEmpty {
            ContentUnavailableView {
                Label("空文件夹", systemImage: "folder")
            } description: {
                Text("将文件拖到此处，或从 Mac 选择要上传的文件。")
            } actions: {
                Button("上传文件…", action: upload)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            table
        }
    }

    private var table: some View {
        let rows = state.folders.map(Row.init(folder:)).sorted(using: sortOrder)
                 + state.objects.map(Row.init(object:)).sorted(using: sortOrder)
        let selection = Binding(get: { state.selectedRowID }, set: { state.setRowSelection($0) })

        return Table(rows, selection: selection, sortOrder: $sortOrder) {
            TableColumn("名称", value: \.name, comparator: .localizedStandard) { row in
                Label {
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: Formatting.icon(forFileName: row.name, isFolder: row.isFolder))
                        .foregroundStyle(row.isFolder ? Color.accentColor : .secondary)
                }
                .help(row.name)
            }
            .width(min: 150, ideal: 340)

            TableColumn("大小", value: \.size) { row in
                if !row.isFolder {
                    Text(Formatting.fileSize(row.size))
                        .monospacedDigit()
                }
            }
            .width(min: 66, ideal: 84, max: 132)
            .alignment(.trailing)

            TableColumn("修改时间", value: \.modified) { row in
                if !row.isFolder {
                    Text(row.modified, format: .dateTime.year().month().day().hour().minute())
                        .monospacedDigit()
                        .lineLimit(1)
                        .help(Formatting.absoluteTime(row.modified))
                }
            }
            .width(min: 116, ideal: 168, max: 220)

            TableColumn("同步状态") { row in
                if let entry = row.entry, let bucket = state.selectedBucket {
                    statusLabel(state.statusPublic(bucket: bucket, key: entry.key))
                }
            }
            .width(min: 88, ideal: 112, max: 170)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds()
        .focused($tableFocused)
        .task {
            if state.focusFileTableOnLoad {
                tableFocused = true
                state.focusFileTableOnLoad = false
            }
        }
        .contextMenu(forSelectionType: Row.ID.self) { items in
            if let row = rows.first(where: { items.contains($0.id) }) {
                rowMenu(row)
            }
        } primaryAction: { items in
            if let row = rows.first(where: { items.contains($0.id) }) {
                activate(row)
            }
        }
        .onKeyPress(.return) {
            guard state.selectedRowID != nil else { return .ignored }
            state.activateSelectedRow()
            return .handled
        }
        .onKeyPress(.space) {
            guard state.selection != nil else { return .ignored }
            state.quickLookSelectedRow()
            return .handled
        }
    }

    private func activate(_ row: Row) {
        if let entry = row.entry {
            Task { await state.openInEditor(entry) }
        } else {
            state.enterFolder(row.key)
        }
    }

    @ViewBuilder private func rowMenu(_ row: Row) -> some View {
        if let entry = row.entry {
            Button("在默认编辑器中打开") { activate(row) }
            Button("Quick Look 预览") { state.quickLook(entry) }
            Divider()
            Button("立即同步") { Task { await state.syncNowEntry(entry) } }
        } else {
            Button("打开") { activate(row) }
        }
        Divider()
        Button("重命名…") { state.renameTarget = row.actionEntry }
        Button("删除…", role: .destructive) { state.deleteTargets = [row.actionEntry] }
    }

    @ViewBuilder private func statusLabel(_ status: FileSyncStatus) -> some View {
        switch status {
        case .synced:
            statusLabel("已同步", symbol: "checkmark.circle", color: .green)
        case .dirty:
            statusLabel("未同步", symbol: "circle.dotted", color: .orange)
        case .uploading:
            statusLabel("上传中", symbol: "arrow.up.circle", color: .blue)
        case .failed(let reason):
            statusLabel("同步失败", symbol: "exclamationmark.triangle", color: .red)
                .help(reason)
        case .conflict:
            statusLabel("冲突", symbol: "exclamationmark.circle", color: .orange)
        case .remoteOnly:
            EmptyView()
        }
    }

    private func statusLabel(_ title: LocalizedStringKey, symbol: String, color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
    }
}

struct BrowserStatusBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !state.prefix.isEmpty {
                breadcrumbs
                Divider()
            }

            HStack(spacing: 8) {
                activity
                Spacer(minLength: 0)
                Text("\(state.folders.count) 个文件夹，\(state.objects.count) 个文件")
                    .monospacedDigit()
                    .fixedSize()
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .background(.bar)
    }

    private var breadcrumbs: some View {
        let parts = state.breadcrumbParts
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(parts, id: \.prefix) { part in
                        if !part.prefix.isEmpty {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        if part.prefix == state.prefix {
                            Text(part.name)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                        } else {
                            Button {
                                state.enterFolder(part.prefix)
                            } label: {
                                Label(part.name, systemImage: part.prefix.isEmpty ? "archivebox" : "folder")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Color.clear.frame(width: 0).id("path-end")
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 14)
                .frame(minHeight: 28)
            }
            .scrollIndicators(.hidden)
            .frame(height: 28)
            .onChange(of: state.prefix, initial: true) { proxy.scrollTo("path-end", anchor: .trailing) }
            .accessibilityLabel("当前路径")
        }
    }

    @ViewBuilder private var activity: some View {
        if state.outage {
            Label("网络已断开，恢复后继续同步", systemImage: "wifi.slash")
                .foregroundStyle(.orange)
        } else if let item = state.transfers.first(where: { $0.state == .active }) {
            Label(item.name, systemImage: item.kind == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .truncationMode(.middle)
                .help(item.name)
            ProgressView(value: item.fraction)
                .controlSize(.small)
                .frame(width: 72)
                .accessibilityLabel(item.kind == .upload ? "上传进度" : "下载进度")
        } else if state.directoryBusy {
            ProgressView()
                .controlSize(.mini)
            Text("正在刷新…")
        } else if let key = state.lastSavedKey {
            Label("已同步 \((key as NSString).lastPathComponent)", systemImage: "checkmark.circle")
                .truncationMode(.middle)
        }
    }
}
