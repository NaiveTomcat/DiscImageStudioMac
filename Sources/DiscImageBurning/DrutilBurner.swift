import Foundation

/// 基于 `drutil` / `hdiutil` 的真机刻录实现（HANDOFF §3.2）。
///
/// 设计要点：
/// 1. **生成与烧录解耦**：这里只负责把已经生成好的文件写进盘；任何失败都不会
///    回滚已经导出的 ISO / WAV+CUE（HANDOFF §3.4 第 1 条）。盘面图案依赖
///    「扇区数恰好落位」，`drutil` 不保证 DAO 字节级控制，所以导出文件永远是
///    用户的可重试资产。
/// 2. **不猜设备**：`deviceID` 为 nil 时只有恰好一台刻录机才允许继续；多于一台
///    直接抛 `ambiguousDevices`，因为 `drutil` 在未指定 `-drive` 时会对**所有**
///    光驱执行同一件事。
/// 3. **先预检再刻录**：每次刻录前跑一次 `drutil status`，把「没盘 / 非空白盘 /
///    容量不足」在烧之前翻译成可执行的中文提示，而不是让 drutil 在写入一半时
///    才报错——那会白毁一张盘。
/// 4. **取消/超时**：交给 `CommandExecutor` 终止子进程；本层负责把
///    `CancellationError` 翻译成「盘片可能报废」的提示。
public struct DrutilBurner: BurnService {
    public let executor: CommandExecutor
    /// 数据盘刻录用哪个工具。默认 `drutil`：它能按 `drutil list` 的序号选光驱。
    public let imageTool: BurnTool
    public let verifyAfterBurn: Bool
    public let ejectAfterBurn: Bool
    /// 进度回调（drutil 的文本进度是尽力而为的，可能稀疏甚至完全没有）。
    public let progress: (@Sendable (BurnProgress) -> Void)?

    public init() {
        self.init(executor: SystemCommandExecutor())
    }

    public init(
        executor: CommandExecutor,
        imageTool: BurnTool = .drutil,
        verifyAfterBurn: Bool = false,
        ejectAfterBurn: Bool = true,
        progress: (@Sendable (BurnProgress) -> Void)? = nil
    ) {
        self.executor = executor
        self.imageTool = imageTool
        self.verifyAfterBurn = verifyAfterBurn
        self.ejectAfterBurn = ejectAfterBurn
        self.progress = progress
    }

    // MARK: - BurnService

    public func listDevices() async throws -> [DiscDevice] {
        let command = BurnCommandBuilder.list()
        let result = try await runQuery(command)
        return DrutilParser.parseDeviceList(result.standardOutput)
    }

    public func status(deviceID: String?) async throws -> DiscStatus {
        let drive = try await resolveDrive(deviceID)
        return try await readStatus(deviceID: drive)
    }

    public func burnAudio(trackURL: URL, deviceID: String?) async throws {
        try Self.validateFile(
            trackURL,
            allowedExtensions: ["wav", "cue", "aiff", "aif", "mp3", "m4a"],
            action: "CD 音轨刻录"
        )
        let drive = try await resolveDrive(deviceID)
        _ = try await preflight(deviceID: drive, requiredBytes: Self.fileSize(trackURL))
        let command = try BurnCommandBuilder.burnAudio(
            trackURL: trackURL,
            deviceID: drive,
            verify: verifyAfterBurn,
            eject: ejectAfterBurn
        )
        try await burn(command)
    }

    public func burnImage(imageURL: URL, deviceID: String?) async throws {
        try Self.validateFile(
            imageURL,
            allowedExtensions: ["iso", "dmg", "cue", "toc", "bin"],
            action: "数据盘刻录"
        )
        let drive = try await resolveDrive(deviceID)
        _ = try await preflight(deviceID: drive, requiredBytes: Self.fileSize(imageURL))
        let command = try BurnCommandBuilder.burnImage(
            imageURL: imageURL,
            deviceID: imageTool == .hdiutil ? nil : drive,
            tool: imageTool,
            verify: verifyAfterBurn,
            eject: ejectAfterBurn
        )
        try await burn(command)
    }

    public func eject(deviceID: String?) async throws {
        let drive = try await resolveDrive(deviceID)
        let command = try BurnCommandBuilder.eject(deviceID: drive)
        _ = try await runQuery(command)
    }

    // MARK: - 内部步骤

    /// 把「用户选的设备」或「唯一的设备」变成一个 `drutil -drive` 序号。
    private func resolveDrive(_ deviceID: String?) async throws -> String {
        if let deviceID, !deviceID.trimmingCharacters(in: .whitespaces).isEmpty {
            return try BurnCommandBuilder.validatedDriveIndex(deviceID)
        }
        let devices = try await listDevices()
        switch devices.count {
        case 0: throw BurnError.noDevice
        case 1: return devices[0].id
        default: throw BurnError.ambiguousDevices(count: devices.count)
        }
    }

    private func readStatus(deviceID: String) async throws -> DiscStatus {
        let command = try BurnCommandBuilder.status(deviceID: deviceID)
        let result = try await runQuery(command)
        let text = result.standardOutput.isEmpty ? result.combinedOutput : result.standardOutput
        return try DrutilParser.parseStatus(text)
    }

    /// 烧之前的预检：空白盘 + 可写 + 容量够。
    private func preflight(deviceID: String, requiredBytes: Int64?) async throws -> DiscStatus {
        let status = try await readStatus(deviceID: deviceID)
        if !status.isBlank {
            throw BurnError.discNotBlank(
                mediaType: status.mediaType.isEmpty ? "未知介质" : status.mediaType
            )
        }
        guard status.isWritable else {
            throw BurnError.unsupportedMedia(
                "\(status.mediaType.isEmpty ? "未知介质" : status.mediaType)（这张盘不能写入）"
            )
        }
        if let requiredBytes, requiredBytes > 0, status.freeBytes > 0, requiredBytes > status.freeBytes {
            throw BurnError.insufficientCapacity(
                requiredBytes: requiredBytes,
                availableBytes: status.freeBytes
            )
        }
        return status
    }

    private func runQuery(_ command: BurnCommand) async throws -> CommandResult {
        let result: CommandResult
        do {
            result = try await executor.run(command)
        } catch let error as BurnError {
            throw error
        } catch is CancellationError {
            // 查询阶段被取消：还没有碰盘，可以安心说「盘片没被写过」。
            throw BurnError.cancelled(discMayBeDamaged: false)
        } catch {
            throw BurnError.toolFailed(
                command: command.displayString,
                exitCode: -1,
                output: error.localizedDescription
            )
        }
        guard result.exitCode == 0 else {
            throw DrutilParser.failure(for: result, command: command)
        }
        return result
    }

    private func burn(_ command: BurnCommand) async throws {
        var lineHandler: (@Sendable (String) -> Void)?
        if let progress {
            lineHandler = { line in
                guard let parsed = DrutilParser.parseProgress(line) else { return }
                progress(parsed)
            }
        }

        let result: CommandResult
        do {
            result = try await executor.run(command, onOutputLine: lineHandler)
        } catch let error as BurnError {
            throw error
        } catch is CancellationError {
            throw BurnError.cancelled(discMayBeDamaged: command.writesDisc)
        } catch {
            throw BurnError.toolFailed(
                command: command.displayString,
                exitCode: -1,
                output: error.localizedDescription
            )
        }

        guard result.exitCode == 0 else {
            throw DrutilParser.failure(for: result, command: command)
        }
        progress?(BurnProgress(stage: .completed, fraction: 1, rawLine: "刻录完成"))
    }

    // MARK: - 文件检查

    static func validateFile(_ url: URL, allowedExtensions: Set<String>, action: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw BurnError.missingFile(url.path)
        }
        let suffix = url.pathExtension.lowercased()
        guard allowedExtensions.contains(suffix) else {
            let allowed = allowedExtensions.sorted().map { ".\($0)" }.joined(separator: " / ")
            throw BurnError.unsupportedMedia(
                "\(action)不支持 \(suffix.isEmpty ? "没有扩展名的文件" : ".\(suffix) 文件")；可接受：\(allowed)"
            )
        }
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            return nil
        }
        return Int64(size)
    }
}
