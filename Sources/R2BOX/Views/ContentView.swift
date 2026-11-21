import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let conflictID = state.conflictDialog?.id
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 224, max: 320)
        } detail: {
            BrowserView()
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: Binding(
            get: { state.showConnectionSheet },
            set: { state.showConnectionSheet = $0 }
        ), onDismiss: state.presentNextConflict) {
            ConnectionSheet()
        }
        .sheet(
            item: Binding(
                get: { state.conflictDialog },
                set: { if $0 == nil, let conflictID { state.resolveConflict(.keepLocalOnly, id: conflictID) } }
            ),
            onDismiss: state.conflictDialogDidDismiss
        ) { ctx in
            VStack(alignment: .leading, spacing: 16) {
                Text("检测到同步冲突")
                    .font(.headline)
                Text(Self.conflictDetail(for: ctx))
                HStack {
                    Button("保留本地文件") { state.resolveConflict(.keepLocalOnly, id: ctx.id) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("重新加载远程") { state.resolveConflict(.reloadRemote, id: ctx.id) }
                    Button("覆盖远程") { state.resolveConflict(.overwriteRemote, id: ctx.id) }
                }
            }
            .padding(24)
            .frame(width: 470)
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } }
            ),
            presenting: state.errorMessage
        ) { _ in
            Button("好") { state.errorMessage = nil }
        } message: { message in
            Text(message)
        }
        .onAppear {
            // selftest 模式：进程里跑的是隔离 AppState，UI 不自动连接真实连接
            guard !CommandLine.arguments.contains("--selftest") else { return }
            if state.connection == nil, let conn = ConnectionManager.shared.selected {
                state.connect(to: conn, focusFileTable: true)
            }
        }
    }

    private static func conflictDetail(for ctx: AppState.ConflictContext) -> String {
        "「\(ctx.file.bucket)/\(ctx.file.key)」的本地和远端版本都已修改。覆盖远程会上传本地版本，重新加载会放弃当前本地修改。"
    }
}
