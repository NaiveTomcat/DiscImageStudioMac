import DiscImageCore
import Foundation

/// 主页「最近打开」的一条记录。
public struct RecentProjectEntry: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    /// 工程项目 token（`cd` / `dvd` / `bd`），存字符串以兼容旧记录。
    public var discFamily: String
    public var projectPath: String
    public var thumbnailPngBase64: String?
    public var lastOpenedUtc: Date

    public var id: String { projectPath }

    public var family: DiscFamily { DiscFamily.fromProjectToken(discFamily) ?? .cd }

    public var familyLabel: String { family.displayNameZH }

    public var projectURL: URL { URL(fileURLWithPath: projectPath) }

    public var fileExists: Bool { FileManager.default.fileExists(atPath: projectPath) }

    public init(
        name: String,
        discFamily: String,
        projectPath: String,
        thumbnailPngBase64: String? = nil,
        lastOpenedUtc: Date = Date()
    ) {
        self.name = name
        self.discFamily = discFamily
        self.projectPath = projectPath
        self.thumbnailPngBase64 = thumbnailPngBase64
        self.lastOpenedUtc = lastOpenedUtc
    }

    public init(project: DiscProject, path: URL, lastOpenedUtc: Date = Date()) {
        self.init(
            name: project.name,
            discFamily: project.discFamily.rawValue,
            projectPath: path.path,
            thumbnailPngBase64: project.thumbnailPngBase64,
            lastOpenedUtc: lastOpenedUtc
        )
    }

    private enum CodingKeys: String, CodingKey {
        case name, discFamily, projectPath, thumbnailPngBase64, lastOpenedUtc
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名工程"
        discFamily = try container.decodeIfPresent(String.self, forKey: .discFamily) ?? "cd"
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath) ?? ""
        thumbnailPngBase64 = try container.decodeIfPresent(String.self, forKey: .thumbnailPngBase64)
        lastOpenedUtc = try container.decodeIfPresent(Date.self, forKey: .lastOpenedUtc) ?? Date()
    }
}

/// 最近工程列表（json 落在 `~/Library/Application Support/DiscImageStudio/recent-projects.json`）。
///
/// 这属于「便利状态」而不是用户数据：读失败退化成空列表，写失败静默忽略，
/// 和源项目 `RecentProjectStore` 的取舍一致。测试可注入临时目录。
public struct RecentProjectStore: Sendable {
    public static let maxEntries = 12
    public static let fileName = "recent-projects.json"

    public let fileURL: URL

    public init(fileURL: URL = RecentProjectStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("DiscImageStudio", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// 记录一次打开：按路径去重、最新的在前、截断到上限。
    public func load() -> [RecentProjectEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([RecentProjectEntry].self, from: data) else {
            return []
        }
        return Self.deduplicated(entries)
    }

    /// 记录一次打开/保存；返回记录后的列表。
    @discardableResult
    public func record(_ entry: RecentProjectEntry) -> [RecentProjectEntry] {
        var entries = load()
        entries.removeAll { $0.projectPath == entry.projectPath }
        entries.insert(entry, at: 0)
        entries = Self.deduplicated(entries)
        save(entries)
        return entries
    }

    public func remove(projectPath: String) -> [RecentProjectEntry] {
        var entries = load()
        entries.removeAll { $0.projectPath == projectPath }
        save(entries)
        return entries
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save(_ entries: [RecentProjectEntry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func deduplicated(_ entries: [RecentProjectEntry]) -> [RecentProjectEntry] {
        var seen: Set<String> = []
        var result: [RecentProjectEntry] = []
        for entry in entries where !entry.projectPath.isEmpty {
            guard seen.insert(entry.projectPath).inserted else { continue }
            result.append(entry)
            if result.count >= maxEntries { break }
        }
        return result.sorted { $0.lastOpenedUtc > $1.lastOpenedUtc }
    }
}
