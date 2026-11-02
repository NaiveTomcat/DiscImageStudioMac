import Foundation

/// 三种介质。原始值与源项目的「工程 token」保持一致（`cd` / `dvd` / `bd`），
/// 因为 `.discproj` 里存的就是这三个字符串。
public enum DiscFamily: String, Codable, CaseIterable, Sendable, Identifiable {
    case cd
    case dvd
    case bluRay = "bd"

    public var id: String { rawValue }

    /// 界面显示名。源项目 UI 里叫「蓝光」，工程 token 仍是 `bd`。
    public var displayNameZH: String {
        switch self {
        case .cd: return "CD"
        case .dvd: return "DVD"
        case .bluRay: return "蓝光"
        }
    }

    /// 兼容 `cd` / `dvd` / `bd`，大小写不敏感；也接受 `bluray` / `blu-ray`。
    public static func fromProjectToken(_ token: String) -> DiscFamily? {
        let normalized = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "cd": return .cd
        case "dvd": return .dvd
        case "bd", "bluray", "bdrom", "bd-r": return .bluRay
        default: return nil
        }
    }

    /// 每扇区通道位（DVD 编码链的装配单位）。CD/BD 返回 nil。
    public var channelBitsPerSector: Int? {
        self == .dvd ? DiscGeometry.dvdChannelBitsPerSector : nil
    }

    /// 该介质允许的灰阶数量。
    public var supportedLevels: [Int] {
        self == .cd ? [2, 4] : [2]
    }
}
