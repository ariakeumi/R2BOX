import AppKit
import SwiftUI

/// 把"新建连接"工具栏按钮推到侧栏区右缘（贴近分隔线）：
/// SwiftUI 的 sidebar 段自带一个固定弹性空间（不可再伸缩），导致按钮贴在红绿灯旁。
/// 在按钮前再插入一个系统 FlexibleSpace，把剩余宽度全部让给它，按钮即右对齐。
@MainActor
struct ToolbarTuner {
    static func install() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow, window.toolbar != nil else { return }
            tune(window: window, attempt: 0)
        }
    }

    private static func tune(window: NSWindow, attempt: Int) {
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let toolbar = window.toolbar else { return }
            let items = toolbar.items
            // "+"项 = 非(弹性空间/分隔/系统开关)的第一个工具栏项
            guard let plusIdx = items.firstIndex(where: { item in
                let id = item.itemIdentifier.rawValue.lowercased()
                let isSystem = id.contains("flexible") || id.contains("space") ||
                    id.contains("toggle") || id.contains("sidebar") ||
                    id.contains("separator") || id.contains("title")
                return !isSystem
            }) else { return }
            // 已紧邻弹性空间则视为完成
            if plusIdx > 0, items[plusIdx - 1].itemIdentifier == .flexibleSpace { return }
            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: plusIdx)
            tune(window: window, attempt: attempt + 1)
        }
    }
}
