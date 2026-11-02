import Foundation

/// 标定会话的 JSON 读写（`.calibration.json` 旁写文件）。
///
/// - 键名 camelCase；日期用 ISO 8601；
/// - schema 6，只接受当前版本（旧梳形图案不迁移）；
/// - 保存前、加载后都会做完整校验；
/// - 写入走「临时文件 + 原子替换」，避免写一半留下坏记录。
public struct CalibrationSessionStore {
    /// 会话 JSON 允许的最大字节数（与上游一致）。
    public static let maximumByteCount = 16_000_000

    public static func encode(_ session: CalibrationSession) throws -> Data {
        try session.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(session)
        } catch {
            throw DiscError.io("标定会话无法编码：\(error.localizedDescription)")
        }
        guard data.count <= maximumByteCount else {
            throw DiscError.io("标定会话文件过大。")
        }
        return data
    }

    public static func decode(_ data: Data) throws -> CalibrationSession {
        guard data.count <= maximumByteCount else {
            throw DiscError.io("标定会话文件过大。")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session: CalibrationSession
        do {
            session = try decoder.decode(CalibrationSession.self, from: data)
        } catch {
            throw DiscError.io("标定会话内容无效：\(error.localizedDescription)")
        }
        try session.validate()
        return session
    }

    public static func save(_ session: CalibrationSession, to url: URL) throws {
        let data = try encode(session)
        let directory = url.deletingLastPathComponent()
        if !directory.path.isEmpty {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DiscError.io("无法写入标定会话 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    public static func load(from url: URL) throws -> CalibrationSession {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DiscError.io("无法读取标定会话 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
        return try decode(data)
    }
}
