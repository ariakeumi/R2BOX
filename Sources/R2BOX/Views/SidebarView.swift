import SwiftUI
import R2BOXCore

/// 侧栏：一个连接就是一个储存桶，直接平铺。
/// - 连接设置了储存桶 → 行主文本为连接名，副文本为实际桶名
/// - 未设置储存桶 → 行主文本为连接名；若该连接处于激活状态且含多个桶，
///   其桶以普通行追加展示（保持可浏览性）
struct SidebarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section("储存桶") {
                if ConnectionManager.shared.connections.isEmpty {
                    Text("暂无连接")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(ConnectionManager.shared.connections) { connection in
                    bucketConnectionRow(connection)

                    // 未限定桶的激活连接：其桶平铺列出（无缩进，同等地位）
                    if isActiveUnpinned(connection) {
                        ForEach(state.buckets) { bucket in
                            bucketRow(bucket)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // 不让位：列表直接从标题条下开始（Section 头"储存桶"贴近交通灯）
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 0)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    state.editingConnection = nil
                    state.showConnectionSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("新建连接")
            }
        }
    }

    private func isActiveUnpinned(_ connection: Connection) -> Bool {
        guard state.connection?.id == connection.id else { return false }
        return connection.bucket.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 连接即储存桶：主文本 = 连接的自定义名称，副文本 = 实际桶名（未设置则不显示）
    @ViewBuilder private func bucketConnectionRow(_ connection: Connection) -> some View {
        let isActive = state.connection?.id == connection.id
        let bucketLabel = connection.bucket.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "archivebox")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(connection.name)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            if !bucketLabel.isEmpty {
                Text(bucketLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive {
                state.connect(to: connection)
            }
        }
        .contextMenu {
            Button("编辑连接…") {
                state.editingConnection = connection
                state.showConnectionSheet = true
            }
            Divider()
            Button("删除连接", role: .destructive) {
                ConnectionManager.shared.delete(connection)
                if let first = ConnectionManager.shared.connections.first {
                    state.connect(to: first)
                } else {
                    state.shutdown()
                }
            }
        }
    }

    @ViewBuilder private func bucketRow(_ bucket: BucketInfo) -> some View {
        let isSelected = state.selectedBucket == bucket.name
        HStack(spacing: 6) {
            Image(systemName: "archivebox")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Text(bucket.name)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            state.selectBucket(bucket.name)
        }
    }
}

