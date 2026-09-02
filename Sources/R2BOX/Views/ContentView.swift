import SwiftUI
import R2BOXCore
import R2BOXSync

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            BrowserView()
        }
        .sheet(isPresented: Binding(
            get: { state.showConnectionSheet },
            set: { state.showConnectionSheet = $0 }
        )) {
            ConnectionSheet()
        }
        .alert(
            "检测到同步冲突",
            isPresented: Binding(
                get: { state.conflictDialog != nil },
                set: { if !$0 { state.resolveConflict(.keepLocalOnly) } }
            ),
            presenting: state.conflictDialog
        ) { ctx in
            Button {
                state.resolveConflict(.overwriteRemote)
            } label: {
                Text("覆盖远程")
            }
            Button {
                state.resolveConflict(.reloadRemote)
            } label: {
                Text("重新加载远程")
            }
            Button {
                state.resolveConflict(.keepLocalOnly)
            } label: {
                Text("保留本地文件")
            }
        } message: { ctx in
            Text(Self.conflictDetail(for: ctx))
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
                state.connect(to: conn)
            }
        }
    }

    private static func conflictDetail(for ctx: AppState.ConflictContext) -> String {
        let name = ctx.file.key.components(separatedBy: "/").last ?? ctx.file.key
        return "「\(name)」在远程已被修改（ETag 不一致），本地也有未同步的修改。\n\n覆盖远程：用本地内容替换远程版本\n重新加载远程：放弃本地修改，下载远程最新版本\n保留本地：暂不上传，保留本地副本"
    }
}
