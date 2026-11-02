import Foundation

/// 待刻入数据盘的一个条目（文件或目录）。
public struct FileTreeEntry: Sendable, Equatable {
    /// 相对根目录的路径，用 `/` 分隔，不带前导斜杠。
    public let relativePath: String
    public let sourceURL: URL
    public let isDirectory: Bool
    public let byteCount: Int64

    public init(relativePath: String, sourceURL: URL, isDirectory: Bool, byteCount: Int64) {
        self.relativePath = relativePath
        self.sourceURL = sourceURL
        self.isDirectory = isDirectory
        self.byteCount = byteCount
    }
}

/// 目录扫描：生成 ISO/UDF 目录树所需的全部条目。
///
/// 安全约定（照搬源项目）：**一律拒绝符号链接**，避免数据盘镜像越界读到
/// 工作目录以外的文件；也拒绝指向目录外的 `..` 路径。
public enum FileTree {
    public static func scan(root: URL, includeDirectories: Bool = true) throws -> [FileTreeEntry] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DiscError.missingPayload("文件夹不存在：\(root.lastPathComponent)")
        }
        if try isSymbolicLink(root) {
            throw DiscError.io("拒绝符号链接：\(root.lastPathComponent)")
        }

        var results: [FileTreeEntry] = []
        let base = root.standardizedFileURL
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard let enumerator = fileManager.enumerator(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            throw DiscError.missingPayload("无法枚举文件夹：\(root.lastPathComponent)")
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                throw DiscError.io("数据盘目录里含符号链接，已拒绝：\(url.lastPathComponent)")
            }
            let standardized = url.standardizedFileURL.path
            guard standardized.hasPrefix(basePath) else {
                throw DiscError.io("路径越界，已拒绝：\(url.lastPathComponent)")
            }
            let relative = String(standardized.dropFirst(basePath.count))
            guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else {
                throw DiscError.io("路径越界，已拒绝：\(url.lastPathComponent)")
            }
            let directory = values.isDirectory == true
            if directory {
                if includeDirectories {
                    results.append(FileTreeEntry(
                        relativePath: relative,
                        sourceURL: url,
                        isDirectory: true,
                        byteCount: 0
                    ))
                }
            } else {
                results.append(FileTreeEntry(
                    relativePath: relative,
                    sourceURL: url,
                    isDirectory: false,
                    byteCount: Int64(values.fileSize ?? 0)
                ))
            }
        }

        // 稳定排序：文件系统枚举顺序不确定，不排序会让同一次输入生成不同镜像。
        results.sort { $0.relativePath < $1.relativePath }
        return results
    }

    /// 递归统计总字节数。
    public static func totalBytes(_ entries: [FileTreeEntry]) -> Int64 {
        entries.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.byteCount) }
    }

    private static func isSymbolicLink(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values.isSymbolicLink == true
    }
}
