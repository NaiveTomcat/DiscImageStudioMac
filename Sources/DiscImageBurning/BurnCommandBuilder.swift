import Foundation

/// 纯函数式的命令构造。
///
/// 这一层刻意不碰 `Process`、不碰任何设备：所有「该敲哪条命令」的知识都在这里，
/// 因此可以在没有刻录机的机器上（包括 GitHub Actions 的 macos-latest）做单元测试。
///
/// 两条来自 man page 的硬约定（写错会刻到错误的光驱上）：
/// 1. **`-drive` 必须出现在动词之前**：`drutil -drive 1 burn …`，不是
///    `drutil burn -drive 1 …`（drutil(1)：「Drive selection arguments must
///    appear before individual arguments」）。
/// 2. 不指定 `-drive` 时，`drutil` 会对**所有**候选光驱执行同一件事。所以
///    `BurnService` 在设备多于一台时必须先让用户选（见 `DrutilBurner`）。
public enum BurnCommandBuilder {
    /// 查询类命令（list / status）的超时。
    public static let queryTimeoutSeconds: TimeInterval = 60
    /// 弹出托盘这类动作的超时。
    public static let ejectTimeoutSeconds: TimeInterval = 120
    /// 刻录默认超时（2 小时：BD-R 25 GB 2x 也要 40 分钟以上，还要留验盘时间）。
    public static let defaultBurnTimeoutSeconds: TimeInterval = 2 * 60 * 60

    // MARK: - 查询与弹出

    /// `drutil list`：枚举设备。
    public static func list() -> BurnCommand {
        BurnCommand(
            executable: BurnTool.drutil.executablePath,
            arguments: ["list"],
            timeoutSeconds: queryTimeoutSeconds
        )
    }

    /// `drutil [-drive n] status`：读取当前介质状态。
    public static func status(deviceID: String?) throws -> BurnCommand {
        var arguments: [String] = []
        if let deviceID { arguments += try driveSelection(deviceID) }
        arguments.append("status")
        return BurnCommand(
            executable: BurnTool.drutil.executablePath,
            arguments: arguments,
            timeoutSeconds: queryTimeoutSeconds
        )
    }

    /// `drutil [-drive n] eject`。
    public static func eject(deviceID: String?) throws -> BurnCommand {
        var arguments: [String] = []
        if let deviceID { arguments += try driveSelection(deviceID) }
        arguments.append("eject")
        return BurnCommand(
            executable: BurnTool.drutil.executablePath,
            arguments: arguments,
            timeoutSeconds: ejectTimeoutSeconds
        )
    }

    // MARK: - 刻录

    /// CD-DA 音频刻录用 `drutil burn -audio`。
    ///
    /// - 传 `.wav`：加 `-audio`，让 drutil 把它当红皮书音轨烧。
    /// - 传 `.cue`：**不加** `-audio`。`.cue` 属于镜像文件（drutil(1) 明确列出
    ///   `.cue/bin`），加 `-audio` 反而会让 drutil 去扫目录里的音频文件。
    /// - `verify` 默认 false：盘面图案靠肉眼验收，验盘只会让一次刻录多花一倍时间。
    /// - `eject`: drutil 默认刻完弹盘，显式 `-noeject` 才能留住盘片。
    public static func burnAudio(
        trackURL: URL,
        deviceID: String?,
        verify: Bool = false,
        eject: Bool = true,
        timeoutSeconds: TimeInterval = defaultBurnTimeoutSeconds
    ) throws -> BurnCommand {
        var arguments: [String] = []
        if let deviceID { arguments += try driveSelection(deviceID) }
        arguments.append("burn")
        if !isCueSheet(trackURL) {
            arguments.append("-audio")
        }
        if !verify { arguments.append("-noverify") }
        if !eject { arguments.append("-noeject") }
        arguments.append(trackURL.path)
        return BurnCommand(
            executable: BurnTool.drutil.executablePath,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            writesDisc: true
        )
    }

    /// 数据盘刻录。
    ///
    /// - `tool: .drutil`：用 `drutil [-drive n] burn <image>`。**默认**，因为它支持
    ///   按序号选光驱（与 `drutil list` 一致），能保证写到用户选中的那台。
    /// - `tool: .hdiutil`：用 `hdiutil burn [-noverifyburn] [-noeject] <image>`。
    ///   注意 hdiutil 的 `-device` 需要 `hdiutil burn -list` 给出的 OpenFirmware
    ///   路径，**不是** drutil 的设备序号，所以用 hdiutil 时不能指定 `deviceID`
    ///   （会给 `BurnError.invalidDeviceID`）。
    public static func burnImage(
        imageURL: URL,
        deviceID: String?,
        tool: BurnTool = .drutil,
        verify: Bool = false,
        eject: Bool = true,
        timeoutSeconds: TimeInterval = defaultBurnTimeoutSeconds
    ) throws -> BurnCommand {
        switch tool {
        case .drutil:
            var arguments: [String] = []
            if let deviceID { arguments += try driveSelection(deviceID) }
            arguments.append("burn")
            if !verify { arguments.append("-noverify") }
            if !eject { arguments.append("-noeject") }
            arguments.append(imageURL.path)
            return BurnCommand(
                executable: BurnTool.drutil.executablePath,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds,
                writesDisc: true
            )
        case .hdiutil:
            if let deviceID {
                throw BurnError.invalidDeviceID(
                    "\(deviceID)（hdiutil 不能按 drutil 的设备序号选光驱；请改用 drutil，或只插一台刻录机）"
                )
            }
            var arguments = ["burn"]
            if !verify { arguments.append("-noverifyburn") }
            if !eject { arguments.append("-noeject") }
            arguments.append(imageURL.path)
            return BurnCommand(
                executable: BurnTool.hdiutil.executablePath,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds,
                writesDisc: true
            )
        }
    }

    // MARK: - 参数校验

    /// `-drive` 只接受正整数（drutil 允许 internal/external 等关键字，那是给人敲的；
    /// 界面里传的必须是列表序号，避免把厂商名当设备）。
    public static func validatedDriveIndex(_ deviceID: String) throws -> String {
        let trimmed = deviceID.trimmingCharacters(in: .whitespaces)
        guard let index = Int(trimmed), index >= 1 else {
            throw BurnError.invalidDeviceID(deviceID)
        }
        return String(index)
    }

    static func driveSelection(_ deviceID: String) throws -> [String] {
        ["-drive", try validatedDriveIndex(deviceID)]
    }

    /// `.cue` / `.bin` 走镜像刻录路径，不加 `-audio`。
    static func isCueSheet(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "cue"
    }
}
