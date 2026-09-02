import Foundation

/// 格式化工具：文件大小、相对时间、文件图标。
public enum Formatting {
    public static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    public static func absoluteTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// 与 Finder 一致的文件图标（SF Symbols 名称）
    public static func icon(forFileName name: String, isFolder: Bool) -> String {
        if isFolder { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "yaml", "yml", "toml", "ini", "conf", "cfg", "env":
            return "doc.text"
        case "json", "jsonc", "plist":
            return "doc.text.magnifyingglass"
        case "md", "markdown", "txt", "rtf", "log":
            return "doc.plaintext"
        case "xml", "html", "htm":
            return "doc.text.below.ecg"
        case "csv", "tsv":
            return "tablecells"
        case "zip", "gz", "tar", "bz2", "xz", "7z":
            return "doc.zipper"
        case "pdf":
            return "doc.richtext"
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg":
            return "photo"
        case "mov", "mp4", "m4v", "avi", "mkv":
            return "film"
        case "mp3", "wav", "aac", "flac", "m4a":
            return "music.note"
        case "sh", "command", "py", "rb", "js", "ts", "swift", "go", "rs", "c", "h", "cpp":
            return "applescript"
        default:
            return "doc"
        }
    }

    /// 文件是否可编辑（双击下载并打开编辑）
    public static func isEditable(_ name: String) -> Bool {
        let editableExts: Set<String> = [
            "yaml", "yml", "toml", "json", "jsonc", "md", "markdown", "txt", "xml",
            "ini", "conf", "cfg", "env", "csv", "tsv", "sh", "py", "rb", "js", "ts",
            "swift", "go", "rs", "c", "h", "cpp", "html", "css", "log", "plist",
        ]
        let ext = (name as NSString).pathExtension.lowercased()
        return editableExts.contains(ext)
    }
}
