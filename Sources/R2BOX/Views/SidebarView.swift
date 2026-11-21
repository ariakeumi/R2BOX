import SwiftUI
import R2BOXCore

struct SidebarView: View {
    @Environment(AppState.self) private var state
    @State private var connectionToRemove: Connection?

    private enum Destination: Hashable {
        case connection(UUID)
        case bucket(connectionID: UUID, name: String)
    }

    private var selection: Binding<Destination?> {
        Binding {
            guard let connection = state.connection else { return nil }
            if isUnpinned(connection), let bucket = state.selectedBucket {
                return .bucket(connectionID: connection.id, name: bucket)
            }
            return .connection(connection.id)
        } set: { destination in
            switch destination {
            case .connection(let id):
                if id != state.connection?.id,
                   let connection = ConnectionManager.shared.connections.first(where: { $0.id == id }) {
                    state.connect(to: connection)
                }
            case .bucket(let id, let name):
                if id == state.connection?.id, name != state.selectedBucket {
                    state.selectBucket(name)
                }
            case nil:
                break
            }
        }
    }

    var body: some View {
        List(selection: selection) {
            Section("储存桶") {
                ForEach(ConnectionManager.shared.connections) { connection in
                    connectionRow(connection)
                        .tag(Destination.connection(connection.id))

                    if state.connection?.id == connection.id, isUnpinned(connection) {
                        ForEach(state.buckets) { bucket in
                            Label(bucket.name, systemImage: "archivebox")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .tag(Destination.bucket(connectionID: connection.id, name: bucket.name))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { state.presentConnectionSheet() }) {
                    Label("新建连接", systemImage: "plus")
                }
                .help("新建连接")
            }
        }
        .alert(
            "移除连接？",
            isPresented: Binding(
                get: { connectionToRemove != nil },
                set: { if !$0 { connectionToRemove = nil } }
            ),
            presenting: connectionToRemove
        ) { connection in
            Button("移除", role: .destructive) {
                ConnectionManager.shared.delete(connection)
                if state.connection?.id == connection.id {
                    if let next = ConnectionManager.shared.selected {
                        state.connect(to: next)
                    } else {
                        state.shutdown()
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { connection in
            Text("将从 R2BOX 移除「\(connection.name)」及其保存的访问凭据。")
        }
    }

    private func isUnpinned(_ connection: Connection) -> Bool {
        connection.bucket.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func connectionRow(_ connection: Connection) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                if !isUnpinned(connection), connection.bucket != connection.name {
                    Text(connection.bucket)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
        } icon: {
            Image(systemName: isUnpinned(connection) ? "externaldrive.connected.to.line.below" : "archivebox")
        }
        .contextMenu {
            Button("编辑连接…") { state.presentConnectionSheet(editing: connection) }
            Divider()
            Button("移除连接…", role: .destructive) { connectionToRemove = connection }
        }
    }
}
