import Foundation

/// 全应用统一的错误类型。
///
/// 每个 case 携带一段中文说明，直接可用于 UI 展示；不要把 `localizedDescription`
/// 之外的英文系统错误原样漏到界面上。
public enum DiscError: Error, LocalizedError, Equatable {
    /// 几何/盘片参数不合法（半径、扇区数、轨距系数等）。
    case invalidGeometry(String)
    /// 当前介质不支持该操作（例如 CD 的四阶灰阶用在 DVD 上）。
    case unsupported(String)
    /// 文件读写失败（含符号链接拒绝、越界路径）。
    case io(String)
    /// 编码链路内部失败（ECC、调制、交织自检不通过等）。
    case encoding(String)
    /// 数据盘模式下缺少负载（文件夹为空或路径不存在）。
    case missingPayload(String)

    public var errorDescription: String? {
        switch self {
        case .invalidGeometry(let detail): return "盘片几何参数不合法：\(detail)"
        case .unsupported(let detail): return "当前介质不支持该操作：\(detail)"
        case .io(let detail): return "文件读写失败：\(detail)"
        case .encoding(let detail): return "编码失败：\(detail)"
        case .missingPayload(let detail): return "缺少数据内容：\(detail)"
        }
    }
}

/// 取消令牌的轻量封装：引擎只要在每个阶段边界检查它即可。
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// 被取消时抛出 `CancellationError`，方便调用方统一处理。
    public func check() throws {
        if isCancelled { throw CancellationError() }
    }
}
