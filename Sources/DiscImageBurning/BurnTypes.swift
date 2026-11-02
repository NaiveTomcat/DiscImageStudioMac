import Foundation

// MARK: - 设备与介质状态

/// 一台可用的刻录机。
///
/// `id` 是 `drutil list` 输出里的 **1 基序号**（就是 `drutil -drive <n>` 接受的数字），
/// 字符串形式保存是为了让 UI 直接塞进 `ForEach` / `Picker` 的 `selection`。
/// 注意它是「本次枚举」的序号：重新插拔设备后再枚举可能换号，所以 UI 应在
/// 打开刻录页和开始刻录前各枚举一次。
public struct DiscDevice: Sendable, Equatable, Identifiable {
    public let id: String
    public let vendor: String
    public let product: String
    public let bus: String
    public let supportLevel: String

    public init(id: String, vendor: String, product: String, bus: String, supportLevel: String) {
        self.id = id
        self.vendor = vendor
        self.product = product
        self.bus = bus
        self.supportLevel = supportLevel
    }

    /// 界面显示名，例如 `HL-DT-ST BD-RE WH16NS40（USB）`。
    public var displayName: String {
        let name = [vendor, product]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let busName = bus.trimmingCharacters(in: .whitespaces)
        guard !busName.isEmpty else { return name.isEmpty ? "刻录机 \(id)" : name }
        return name.isEmpty ? busName : "\(name)（\(busName)）"
    }

    /// 该设备支持的能力标记（`drutil list` 的 SupportLevel 列，已小写、去空白）。
    public var capabilities: [String] {
        supportLevel
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// 是否至少支持一种可写介质（`Unsupported` 的驱动器不能刻录）。
    public func supportsAnyRecordableMedia() -> Bool {
        capabilities.contains { capability in
            capability.contains("-r") || capability.contains("+r")
                || capability.contains("rw") || capability.contains("ram")
                || capability.contains("recordable")
        }
    }
}

/// 当前盘片状态（来自 `drutil status`）。
///
/// 容量单位是字节；`freeBytes == 0` 有两种含义：「盘已写满」和「系统没报」，所以
/// 调用方在做容量预检时必须先看 `capacityBytes > 0` 再看 `freeBytes`。
public struct DiscStatus: Sendable, Equatable {
    public let isBlank: Bool
    public let mediaType: String
    public let capacityBytes: Int64
    public let freeBytes: Int64
    public let isWritable: Bool

    public init(
        isBlank: Bool,
        mediaType: String,
        capacityBytes: Int64,
        freeBytes: Int64,
        isWritable: Bool
    ) {
        self.isBlank = isBlank
        self.mediaType = mediaType
        self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes
        self.isWritable = isWritable
    }

    /// 介质信息完全不可用时的占位值（UI 初始状态用）。
    public static let unknown = DiscStatus(
        isBlank: false,
        mediaType: "",
        capacityBytes: 0,
        freeBytes: 0,
        isWritable: false
    )

    /// 已用字节数（容量未知时返回 0）。
    public var usedBytes: Int64 {
        max(0, capacityBytes - freeBytes)
    }

    /// 已用比例 0…1（容量未知时返回 nil，UI 应显示不确定进度）。
    public var usedFraction: Double? {
        guard capacityBytes > 0 else { return nil }
        return min(max(Double(usedBytes) / Double(capacityBytes), 0), 1)
    }
}

// MARK: - 刻录进度

/// 刻录进度事件。
///
/// `drutil` / `hdiutil` 的进度输出**不是稳定接口**，不同 macOS 版本、不同介质
/// 的行文差别很大（有的是 `Burning: 42.0% complete`，有的是一串点号加百分比）。
/// 所以这里只用「关键字 + 百分比」做容错解析；解析不出百分比时 `fraction` 为 nil，
/// UI 应显示不确定进度条。原始行保留在 `rawLine` 里，便于用户回报问题时贴日志。
public struct BurnProgress: Sendable, Equatable {
    public enum Stage: String, Sendable, Equatable {
        case preparing
        case writing
        case verifying
        case finishing
        case completed
        case failed
    }

    public let stage: Stage
    /// 0…1；解析不出时为 nil。
    public let fraction: Double?
    /// 触发本次进度的原始输出行（已去首尾空白）。
    public let rawLine: String

    public init(stage: Stage, fraction: Double?, rawLine: String) {
        self.stage = stage
        self.fraction = fraction
        self.rawLine = rawLine
    }

    public var percentText: String? {
        fraction.map { String(format: "%.0f%%", $0 * 100) }
    }
}

// MARK: - 错误

/// 刻录相关的全部错误。
///
/// 每个 case 都带一句能直接放进对话框的中文说明（`errorDescription`）和一句
/// 「所以现在该做什么」（`recoverySuggestion`）。不要把 `Process` 的英文 errno
/// 原样抛到界面上——`localizedDescription` 已经做了翻译。
public enum BurnError: Error, LocalizedError, Equatable, Sendable {
    /// 找不到可执行文件（`/usr/bin/drutil` 或 `/usr/bin/hdiutil` 缺失）。
    case commandMissing(String)
    /// 系统没有任何刻录机。
    case noDevice
    /// 有多台刻录机，但调用方没有指定用哪一台（不能猜，猜错会烧错盘）。
    case ambiguousDevices(count: Int)
    /// 刻录机里没有盘片。
    case noMedia(device: String?)
    /// 盘片不是空白盘。
    case discNotBlank(mediaType: String)
    /// 盘片容量不足以放下要写的内容。
    case insufficientCapacity(requiredBytes: Int64, availableBytes: Int64)
    /// 权限不足（光驱被占用、无访问权限等）。
    case permissionDenied(String)
    /// 光驱忙（被其他程序占用）。
    case deviceBusy(String)
    /// 介质类型不支持该操作（例如往 DVD 里刻 CD-DA 音轨）。
    case unsupportedMedia(String)
    /// 设备标识非法（UI 传了一个不是数字的 id）。
    case invalidDeviceID(String)
    /// 要刻录的文件不存在 / 不是普通文件。
    case missingFile(String)
    /// 用户取消。`discMayBeDamaged` 为 true 时盘片可能已经写了一半。
    case cancelled(discMayBeDamaged: Bool)
    /// 命令超时。`discMayBeDamaged` 同上。
    case timedOut(seconds: Double, discMayBeDamaged: Bool)
    /// 命令失败且没有更具体的分类。
    case toolFailed(command: String, exitCode: Int32, output: String)
    /// `drutil status` 输出无法解析。
    case unparsableStatus(String)

    public var errorDescription: String? {
        switch self {
        case .commandMissing(let path):
            return "系统里找不到 \(path)。"
        case .noDevice:
            return "没有检测到刻录机。"
        case .ambiguousDevices(let count):
            return "检测到 \(count) 台刻录机，但还没有选定要写入哪一台。"
        case .noMedia(let device):
            if let device {
                return "刻录机（\(device)）里没有盘片。"
            }
            return "刻录机里没有盘片。"
        case .discNotBlank(let mediaType):
            return "这张盘不是空白盘（类型：\(mediaType.isEmpty ? "未知" : mediaType)）。"
        case .insufficientCapacity(let requiredBytes, let availableBytes):
            // 预检失败时能给出确切字节数；drutil 自己报容量错误时拿不到，只给一句人话。
            guard requiredBytes > 0, availableBytes > 0 else {
                return "盘片容量不足：这张盘放不下要写入的内容。"
            }
            return "盘片容量不足：需要 \(BurnFormat.byteCount(requiredBytes))，这张盘只剩 \(BurnFormat.byteCount(availableBytes))。"
        case .permissionDenied(let detail):
            return "系统拒绝了刻录操作，权限不足\(detail.isEmpty ? "。" : "：\(detail)")"
        case .deviceBusy(let detail):
            return "刻录机正被其他程序占用\(detail.isEmpty ? "。" : "（\(detail)）")"
        case .unsupportedMedia(let detail):
            return "当前介质不支持这项操作：\(detail)"
        case .invalidDeviceID(let raw):
            return "设备标识不合法：\(raw)"
        case .missingFile(let path):
            return "找不到要刻录的文件：\(path)"
        case .cancelled(let damaged):
            return damaged ? "刻录已取消，盘片可能已经写入一部分。" : "操作已取消。"
        case .timedOut(let seconds, let damaged):
            let base = "刻录命令超过 \(Int(seconds)) 秒没有响应，已强制结束。"
            return damaged ? base + "盘片可能已经写入一部分。" : base
        case .toolFailed(let command, let exitCode, let output):
            let tail = output.isEmpty ? "" : "系统输出：\(output)"
            return "刻录命令执行失败：\(command)（退出码 \(exitCode)）。\(tail)"
        case .unparsableStatus(let raw):
            let head = raw.isEmpty ? "（空）" : String(raw.prefix(300))
            return "无法解析 drutil 的状态输出：\(head)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .commandMissing:
            return "drutil / hdiutil 是 macOS 自带命令，缺失说明系统不完整。请先修复系统；也可以改用「导出镜像」，再用其他刻录软件写入。"
        case .noDevice:
            return "请用 USB 连接刻录光驱，插好电源与数据线，然后在终端运行 `drutil list` 确认系统能识别；识别到之后回到刻录页点「刷新设备」。"
        case .ambiguousDevices:
            return "请在刻录页的设备列表里选中一台刻录机再开始刻录。应用不会替你猜设备——烧错盘的代价太高。"
        case .noMedia:
            return "请放入一张空白可写盘片（CD-R / DVD-R / BD-R），再刷新状态。"
        case .discNotBlank:
            return "盘面图案只能写在空白盘上。请换一张空白 CD-R / DVD-R / BD-R；RW 盘请先用「磁盘工具」或 `drutil erase quick` 擦除。"
        case .insufficientCapacity:
            return "请换容量更大的盘片（例如 4.7 GB 的 DVD-5 / 25 GB 的 BD-R），或在设计页减少随盘文件、缩小绘图区。"
        case .permissionDenied:
            return "请先确认盘片可写、光驱没有被「磁盘工具」或其他刻录软件占用；如仍失败，请检查系统设置里的隐私与安全授权，然后重试。"
        case .deviceBusy:
            return "请退出其他正在读写该光驱的程序（「磁盘工具」的刻录任务、其他刻录软件），等待几秒后重试。"
        case .unsupportedMedia:
            return "请放入与介质匹配的盘片：CD-DA 音轨只能刻 CD-R/CD-RW，DVD 与蓝光请用对应的 -R 盘片。"
        case .invalidDeviceID:
            return "请回到刻录页点「刷新设备」重新选择一台刻录机。"
        case .missingFile:
            return "请回到导出页重新生成镜像，或重新选择要刻录的文件。"
        case .cancelled(let damaged):
            return damaged
                ? "刻录机已经停止写入。这张盘可能报废，请不要把它用于重要数据；确认盘面后可以换一张空白盘重新刻录。"
                : "没有写入任何内容，盘片仍然可用。"
        case .timedOut(_, let damaged):
            return damaged
                ? "请检查 USB 连接与光驱供电后重试；这张盘可能报废，请换一张空白盘。"
                : "请检查设备连接后重试。"
        case .toolFailed:
            return "请把「系统输出」里的原文和上面的命令一起反馈；如果换盘、换口后仍然失败，多半是光驱或介质问题。"
        case .unparsableStatus:
            return "请把设备的原始输出反馈给开发者；在修复前可以手动用 `drutil status` 确认真实状态。"
        }
    }

    /// 这次失败是否可能已经损坏盘片（决定提示语气）。
    public var discMayBeDamaged: Bool {
        switch self {
        case .cancelled(let damaged), .timedOut(_, let damaged): return damaged
        case .toolFailed, .permissionDenied, .deviceBusy: return true
        default: return false
        }
    }
}

// MARK: - 容量格式化

/// 容量与百分比的中文格式化（刻意不依赖 `ByteCountFormatter`：它的输出随
/// 系统语言/区域变化，单元测试和用户截图文案都需要稳定结果）。
public enum BurnFormat {
    public static func byteCount(_ bytes: Int64) -> String {
        if bytes < 0 { return "未知容量" }
        if bytes == 0 { return "0 B" }
        if bytes < 1_000_000 { return String(format: "%.0f KB", Double(bytes) / 1_000) }
        if bytes < 1_000_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        return String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }

    /// 「42%」这种界面文案；nil 表示不知道进度。
    public static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "---" }
        return String(format: "%.0f%%", min(max(fraction, 0), 1) * 100)
    }
}
