import SwiftUI
import R2BOXCore
import R2BOXSync

// MARK: - 面包屑

struct BreadcrumbView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.prefix.isEmpty {
            EmptyView()   // 根目录：无文件夹层级，不显示面包屑条
        } else {
            breadcrumbBar
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(state.breadcrumbParts.enumerated()), id: \.offset) { index, part in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        state.enterFolder(part.prefix)
                    } label: {
                        Text(part.name.isEmpty ? "/" : part.name)
                            .font(.callout)
                            .fontWeight(index == state.breadcrumbParts.count - 1 ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == state.breadcrumbParts.count - 1 ? Color.primary : Color.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

// MARK: - 文件列表

struct FileListView: View {
    @Environment(AppState.self) private var state

    /// 目录行（文件夹 / 对象统一行模型）
    struct Row: Identifiable, Hashable {
        let id: String          // "dir:<prefix>" 或 "obj:<key>"
        let displayName: String
        let isFolder: Bool
        let entry: ObjectEntry? // 文件夹为 nil

        static func folder(_ prefix: String) -> Row {
            let trimmed = String(prefix.dropLast(prefix.hasSuffix("/") ? 1 : 0))
            let name = trimmed.components(separatedBy: "/").last ?? trimmed
            return Row(id: "dir:" + prefix, displayName: name, isFolder: true, entry: nil)
        }

        static func object(_ entry: ObjectEntry) -> Row {
            Row(id: "obj:" + entry.key, displayName: entry.fileName, isFolder: false, entry: entry)
        }

        var key: String {
            isFolder ? String(id.dropFirst(4)) : (entry?.key ?? "")
        }
    }

    private var rows: [Row] {
        var list = state.folders.map { Row.folder($0) }
        list += state.objects.map { Row.object($0) }
        return list
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .onChange(of: state.objects) { _, _ in keepSelectionValid() }
        .onAppear { KeyHandler.shared.install() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("空文件夹", systemImage: "tray")
        } description: {
            Text("把文件拖到这里上传，或使用工具栏的上传按钮")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        let data = rows
        let selectionBinding = Binding(
            get: { state.selectedRowID.map { Set([$0]) } ?? Set<String>() },
            set: { newValue in
                state.setRowSelection(newValue.first)
            }
        )
        return Table(of: Row.self, selection: selectionBinding, sortOrder: Binding.constant([KeyPathComparator<Row>(\.displayName)])) {
            TableColumn("名称") { row in nameCell(row) }
            TableColumn("大小") { row in sizeCell(row) }
            TableColumn("修改时间") { row in modifiedCell(row) }
            TableColumn("状态") { row in statusCell(row) }
        } rows: {
            ForEach(data) { row in
                TableRow(row)
                    .contextMenu { rowMenu(row) }
            }
        }
        // 键盘兜底（列表聚焦时生效；主通道是 KeyHandler 窗口级监听）
        .onKeyPress(.return) { state.activateSelectedRow(); return .handled }
        .onKeyPress(.space) { state.quickLookSelectedRow(); return .handled }
    }



    // MARK: 单元格

    private func nameCell(_ row: Row) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: row))
                .foregroundStyle(row.isFolder ? Color.accentColor : Color.secondary)
                .font(.body)
            Text(row.displayName)
                .fontWeight(row.isFolder ? .medium : .regular)
            syncBadge(for: row)
        }
    }

    private func sizeCell(_ row: Row) -> some View {
        Group {
            if let entry = row.entry {
                Text(Formatting.fileSize(entry.size))
            } else {
                Text("--")
            }
        }
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private func modifiedCell(_ row: Row) -> some View {
        Group {
            if let entry = row.entry {
                Text(Formatting.relativeTime(entry.lastModified))
            } else {
                Text("")
            }
        }
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private func statusCell(_ row: Row) -> some View {
        Text(statusText(for: row))
            .foregroundStyle(.secondary)
    }

    // MARK: 行为

    private func keepSelectionValid() {
        guard let id = state.selectedRowID else { return }
        if id.hasPrefix("obj:") {
            let key = String(id.dropFirst(4))
            if !state.objects.contains(where: { $0.key == key }) {
                state.setRowSelection(nil)
            }
        } else if !state.listRowIDs.contains(id) {
            state.setRowSelection(nil)
        }
    }

    private func activate(_ row: Row) {
        if row.isFolder {
            state.enterFolder(row.key)
        } else if let entry = row.entry {
            Task { await state.openInEditor(entry) }
        }
    }

    @ViewBuilder private func rowMenu(_ row: Row) -> some View {
        if row.isFolder {
            Button("打开") { activate(row) }
            Divider()
            Button("重命名…") {
                state.renameTarget = ObjectEntry(key: row.key, size: 0, lastModified: Date(), etag: "")
            }
            Button("删除…", role: .destructive) {
                state.deleteTargets = [ObjectEntry(key: row.key, size: 0, lastModified: Date(), etag: "")]
            }
        } else if let entry = row.entry {
            Button("在默认编辑器中打开") {
                Task { await state.openInEditor(entry) }
            }
            Button("Quick Look 预览") { state.quickLook(entry) }
            Divider()
            Button("立即同步") {
                Task { await state.syncNowEntry(entry) }
            }
            Divider()
            Button("重命名…") { state.renameTarget = entry }
            Button("删除…", role: .destructive) { state.deleteTargets = [entry] }
        }
    }

    // MARK: 显示辅助

    private func icon(for row: Row) -> String {
        if row.isFolder { return "folder.fill" }
        return Formatting.icon(forFileName: row.displayName, isFolder: false)
    }

    @ViewBuilder private func syncBadge(for row: Row) -> some View {
        if !row.isFolder, let bucket = state.selectedBucket, let entry = row.entry {
            switch state.statusPublic(bucket: bucket, key: entry.key) {
            case .synced:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("已同步")
            case .dirty:
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.orange)
                    .help("本地有未同步修改")
            case .uploading:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.blue)
                    .help("上传中")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help("同步失败")
            case .conflict:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("存在冲突，等待处理")
            case .remoteOnly:
                EmptyView()
            }
        }
    }

    private func statusText(for row: Row) -> String {
        guard !row.isFolder, let bucket = state.selectedBucket, let entry = row.entry else { return "" }
        switch state.statusPublic(bucket: bucket, key: entry.key) {
        case .synced: return "✓ 已同步"
        case .dirty: return "未同步"
        case .uploading: return "上传中…"
        case .failed: return "失败"
        case .conflict: return "冲突"
        case .remoteOnly: return ""
        }
    }
}

// MARK: - 状态栏

struct StatusBarView: View {
    @Environment(AppState.self) private var state

    private var activeTransfers: [AppState.TransferItem] {
        state.transfers.filter { $0.state == .active }
    }

    var body: some View {
        HStack(spacing: 12) {
            if state.outage {
                Label("网络中断 — 本地修改已保留，恢复后自动续传", systemImage: "wifi.slash")
                    .foregroundStyle(.red)
            } else if let item = activeTransfers.first {
                HStack(spacing: 6) {
                    Image(systemName: item.kind == .upload ? "arrow.up.circle" : "arrow.down.circle")
                        .foregroundStyle(.blue)
                    Text(item.kind == .upload ? "上传" : "下载")
                    Text(item.name)
                        .fontWeight(.medium)
                    ProgressView(value: item.fraction)
                        .frame(width: 110)
                    Text("\(Int(item.fraction * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else if let saved = state.lastSavedKey {
                let name = saved.components(separatedBy: "/").last ?? saved
                Label("✓ \(name) 已同步", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Spacer()

            Text("\(state.folders.count) 个文件夹，\(state.objects.count) 个文件")
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Divider()
                .frame(height: 12)

            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text("工作区 ~/Library/Application Support/R2BOX/workspace")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
