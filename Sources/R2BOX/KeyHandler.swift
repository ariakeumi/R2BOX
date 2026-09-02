import AppKit
import Foundation

/// 窗口级键盘处理（Finder 式）：
/// - ↑ / ↓ 移动文件列表选中项
/// - Enter 打开（文件夹进入 / 文件用默认编辑器打开）
/// - 空格 Quick Look 预览
///
/// 不用 SwiftUI onKeyPress / 菜单裸键快捷键的原因：
/// Table 内部会吞按键且初始焦点在侧栏，onKeyPress 不可靠；
/// 裸键菜单项会全局劫持表单输入。这里用 local monitor 统一接管，
/// 且只在"文件列表处于活动状态、无文本输入、无弹窗"时生效。
@MainActor
final class KeyHandler {
    static let shared = KeyHandler()
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // 只处理无修饰键的方向/回车/空格（⌘组合键交给菜单）
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
        guard let window = NSApp.keyWindow, window === NSApp.mainWindow else { return event }
        guard NSApp.modalWindow == nil else { return event }
        // 文本编辑中（连接表单、重命名、搜索框等）绝不接管
        if window.firstResponder is NSTextView || window.firstResponder is NSText { return event }

        let app = SharedState.app
        // 有弹层（连接表单/冲突/重命名/删除确认/错误提示）时不接管
        guard !app.keyboardBlocked else { return event }

        switch event.keyCode {
        case 125:  // ↓
            app.moveSelection(1)
            return nil
        case 126:  // ↑
            app.moveSelection(-1)
            return nil
        case 36, 76:  // Return / 小键盘 Enter
            app.activateSelectedRow()
            return nil
        case 49:  // Space
            app.quickLookSelectedRow()
            return nil
        default:
            return event
        }
    }
}
