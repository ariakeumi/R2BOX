import Foundation

/// 简单防抖器：fire 合并高频调用，延迟后执行最后一次。
public actor Debouncer {
    private let delay: Duration
    private var task: Task<Void, Never>?

    public init(delay: Duration) {
        self.delay = delay
    }

    public func fire(_ action: @escaping @Sendable () async -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            task = nil
            await action()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}
