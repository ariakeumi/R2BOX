import SwiftUI

@main
struct R2BOXApp: App {
    private let appState = SharedState.app

    init() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1080, height: 680)
        .commands { AppCommands() }

        Settings {
            SettingsView()
                .environment(appState)
                .frame(width: 500, height: 200)
        }
    }
}

/// 全局共享的 AppState（Commands 菜单也需要访问）
@MainActor
enum SharedState {
    static let app = AppState()
}

// MARK: - 菜单命令

struct AppCommands: Commands {
    private var state: AppState { SharedState.app }

    var body: some Commands {
        // 移除 WindowGroup 默认的"新建窗口 ⌘N"
        CommandGroup(replacing: .newItem) { }

        CommandGroup(after: .newItem) {
            Button("新建连接…") {
                state.presentConnectionSheet()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // ⌘1…9 切换侧边栏连接（一个连接=一个储存桶，顺序与侧栏一致；超过 9 个无快捷键）
        CommandMenu("储存桶") {
            ForEach(Array(ConnectionManager.shared.connections.enumerated()), id: \.element.id) { index, connection in
                let bucket = connection.bucket.trimmingCharacters(in: .whitespaces)
                let label = bucket.isEmpty ? connection.name : "\(connection.name)（\(bucket)）"
                if index < 9 {
                    Button(label) {
                        if state.connection?.id != connection.id {
                            state.connect(to: connection)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                } else {
                    Button(label) {
                        if state.connection?.id != connection.id {
                            state.connect(to: connection)
                        }
                    }
                }
            }
        }

        CommandMenu("前往") {
            Button("在默认编辑器中打开") {
                if let selection = state.selection {
                    Task { await state.openInEditor(selection) }
                }
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(state.selection == nil)

            Button("返回上级文件夹") {
                state.navigateUp()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(state.prefix.isEmpty)
        }

        CommandMenu("同步") {
            Button("立即同步") {
                Task { await state.syncNow() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(state.selection == nil)
        }
    }
}
