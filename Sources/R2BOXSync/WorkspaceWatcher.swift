import Foundation
import CoreServices
import Darwin

/// 基于 FSEvents 的目录监听，回调带回相对 directory 的路径。
public final class WorkspaceWatcher: @unchecked Sendable {
    public static let metadataFolderName = ".r2box"
    /// 各 bucket 目录下的下载临时文件夹（下载完成后原子 rename，事件不参与同步）
    public static let tempFolderName = ".__r2box_tmp"
    private var stream: FSEventStreamRef?
    private var box: CallbackBox?
    private let watchedURL: URL
    private let onPaths: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "dev.r2box.fsevents")

    public init(watch directory: URL, onPaths: @escaping @Sendable ([String]) -> Void) {
        // FSEvents 回调报告的是解析后的真实路径（如 /private/var/...），
        // 若监听 /var、/tmp 等符号链接路径，前缀匹配会全部落空 → 事件被丢弃。
        // 因此这里用 realpath(3) 把监听路径归一化为真实形态（Foundation 的
        // resolvingSymlinksInPath 反而会把 /private 前缀剥掉，不能用）。
        var path = directory.path
        if let real = realpath(path, nil) {
            defer { free(real) }
            path = String(cString: real)
        }
        self.watchedURL = URL(fileURLWithPath: path, isDirectory: true)
        self.onPaths = onPaths
    }

    public func start() {
        guard stream == nil else { return }
        let box = CallbackBox(self)
        self.box = box
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let paths = [watchedURL.path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagWatchRoot
        )
    let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
        guard let info else { return }
        let holder = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        let watcher = holder.watcher
        let events = unsafeBitCast(paths, to: NSArray.self) as! [String]
        let base = watcher.watchedURL.path + "/"
        var relative: [String] = []
        for path in events.prefix(count) {
            // 回调路径已归一化（见 init），但稳妥起见仍兼容符号链接形态
            var p = path
            if p.hasPrefix("/private") && !base.hasPrefix("/private"), let real = realpath(p, nil) {
                defer { free(real) }
                p = String(cString: real)
            }
            guard p.hasPrefix(base) else { continue }
            relative.append(String(p.dropFirst(base.count)))
        }
        guard !relative.isEmpty else { return }
        watcher.onPaths(relative)
    }
        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15,
            flags
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        box = nil
    }

    deinit { stop() }

    private final class CallbackBox {
        let watcher: WorkspaceWatcher
        init(_ w: WorkspaceWatcher) { watcher = w }
    }
}
