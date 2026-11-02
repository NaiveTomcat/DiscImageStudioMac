import DiscImageCore
import Foundation

/// `.discproj` 的读写。
///
/// 与源项目 `ProjectJsonStore` 对齐：严格 JSON、camelCase、缩进输出、
/// 先写同目录临时文件再原子替换（崩溃不会留下半个工程）。
/// 日期统一 ISO 8601（带毫秒、UTC），同时容忍旧格式/数值日期。
public struct ProjectStore: Sendable {
    public init() {}

    /// `~/Documents/DiscImageStudio Projects`
    public static var defaultProjectsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return documents.appendingPathComponent("DiscImageStudio Projects", isDirectory: true)
    }

    // MARK: - 编解码

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ProjectDateCoding.string(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                if let date = ProjectDateCoding.date(from: text) {
                    return date
                }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "无法解析日期「\(text)」"
                )
            }
            // 兼容 JSONEncoder 默认的「2001 起算秒数」。
            let seconds = try container.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return decoder
    }

    /// 编码成 JSON 数据（保存与测试共用）。纯函数：不改时间戳。
    public func encode(_ project: DiscProject) throws -> Data {
        try project.validate()
        var clean = project
        clean.schemaVersion = DiscProject.currentSchemaVersion
        return try Self.makeEncoder().encode(clean)
    }

    /// 从 JSON 数据解码。`sourceName` 只用于错误信息。
    public func decode(_ data: Data, sourceName: String = "工程") throws -> DiscProject {
        do {
            let project = try Self.makeDecoder().decode(DiscProject.self, from: data)
            try project.validate()
            return project
        } catch let error as DecodingError {
            throw DiscError.io("工程文件「\(sourceName)」格式不正确：\(Self.describe(error))")
        } catch let error as DiscError {
            throw DiscError.io("工程文件「\(sourceName)」校验失败：\(error.errorDescription ?? "未知错误")")
        }
    }

    public func load(from url: URL) throws -> DiscProject {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DiscError.io("无法读取工程文件「\(url.lastPathComponent)」：\(error.localizedDescription)")
        }
        return try decode(data, sourceName: url.lastPathComponent)
    }

    /// 保存。校验 → 写临时文件 → 原子替换。
    @discardableResult
    public func save(_ project: DiscProject, to url: URL) throws -> DiscProject {
        var document = project
        document.schemaVersion = DiscProject.currentSchemaVersion
        document.modifiedUtc = Date()
        try document.validate()

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data: Data
        do {
            data = try Self.makeEncoder().encode(document)
        } catch let error as DiscError {
            throw error
        } catch {
            throw DiscError.io("工程序列化失败：\(error.localizedDescription)")
        }

        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporaryURL, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw DiscError.io("工程保存失败（\(url.lastPathComponent)）：\(error.localizedDescription)")
        }
        return document
    }

    /// 是否是 `.discproj` 后缀（文件选择器用）。
    public static func looksLikeProject(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == DiscProject.fileExtension
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _):
            return "缺少字段「\(key.stringValue)」"
        case .typeMismatch(_, let context):
            return "字段类型不匹配（\(context.codingPath.map(\.stringValue).joined(separator: "."))）"
        case .valueNotFound(_, let context):
            return "字段为空（\(context.codingPath.map(\.stringValue).joined(separator: "."))）"
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return "未知解码错误"
        }
    }
}

/// 工程文件日期格式：写出带毫秒 ISO 8601（UTC），读取容忍多种写法。
enum ProjectDateCoding {
    private static let preciseFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let fractionalCommaFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func string(from date: Date) -> String {
        preciseFormatter.string(from: date)
    }

    static func date(from text: String) -> Date? {
        if let date = preciseFormatter.date(from: text) { return date }
        if let date = plainFormatter.date(from: text) { return date }
        // 源项目（.NET）写出的 7 位小数：截到 3 位再试一次。
        if let dot = text.firstIndex(of: "."),
           let offset = text[dot...].firstIndex(where: { $0 == "+" || $0 == "Z" || $0 == "-" }) {
            let fraction = text[text.index(after: dot)..<offset]
            if fraction.count > 3 {
                let head = text[..<dot]
                let tail = text[offset...]
                let truncated = "\(head).\(fraction.prefix(3))\(tail)"
                if let date = preciseFormatter.date(from: truncated) { return date }
                if let date = plainFormatter.date(from: String(truncated)) { return date }
            }
        }
        if let date = fractionalCommaFormatter.date(from: text.replacingOccurrences(of: ",", with: ".")) {
            return date
        }
        return nil
    }
}

/// 工程名 → 安全的文件名（去掉 `/` 与空白收边）。
public enum ProjectNaming {
    public static func sanitizedFileStem(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "未命名工程" : trimmed
        let replaced = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return replaced.isEmpty ? "未命名工程" : replaced
    }
}
