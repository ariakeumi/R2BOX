import Foundation

/// 双击打开 / Quick Look 时的决策：直接使用本地副本，还是重新下载远程内容。
/// 纯函数，供 AppState 与校验器共同使用。
public enum OpenPlan: Equatable {
    /// 打开本地副本（与远程一致，或本地有未上传修改而远程未变）
    case useLocal
    /// 重新下载（本地缺失 / 远程已更新且本地无修改 / 0 字节残留 / 无跟踪记录的孤儿副本）
    case downloadRemote
    /// 双方都改过：打开本地并保留旧 baseETag（不重新登记），
    /// 下次保存上传将命中 If-Match 失败 → 冲突弹窗
    case useLocalExpectConflict
}

public enum OpenDecision {
    public static func plan(
        localExists: Bool,
        remoteSize: Int64,
        trackedBaseETag: String?,
        currentETag: String,
        syncedMtime: Date?,
        syncedSize: Int64?,
        localMtime: Date?,
        localSize: Int64?
    ) -> OpenPlan {
        guard localExists, let base = trackedBaseETag else { return .downloadRemote }

        // 本地 0 字节而远程非空：历史上空文件窗口 bug / 污染残留的特征，
        // 无论跟踪记录如何都重新下载，避免把陈旧空副本当"最新"打开
        if localSize == 0 && remoteSize > 0 { return .downloadRemote }

        let fingerprintMatch: Bool? = {
            guard let sm = syncedMtime, let ss = syncedSize,
                  let lm = localMtime, let ls = localSize else { return nil }
            return sm == lm && ss == ls
        }()

        if base == currentETag {
            // 远程自上次同步后未变：本地是权威副本（本地未上传的修改交给 FSEvents 上传）
            return .useLocal
        }
        // 远程已变化：
        // - 本地有未同步修改（指纹不符）→ 打开本地，保留旧基线，保存时触发冲突
        // - 指纹未知（旧版记录/异常状态）→ 同样视为可能有未同步修改，绝不静默覆盖
        // - 本地干净（指纹与上次同步一致）→ 重新下载
        if fingerprintMatch == true { return .downloadRemote }
        return .useLocalExpectConflict
    }
}
