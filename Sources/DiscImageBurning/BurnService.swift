import Darwin
import Foundation

// MARK: - 刻录服务协议

/// 刻录后端。
///
/// 界面只依赖这个协议：真机用 `DrutilBurner`，没有光驱的机器/预览/测试用
/// `MockBurnService`。所有方法都是 `async throws`，并且都接受**可空的设备标识**：
/// - 传 `nil` 表示「让后端自己挑」——只有恰好一台刻录机时才允许，多于一台会
///   抛 `BurnError.ambiguousDevices`，绝不替用户猜（烧错盘的代价太高）。
/// - 传 `DiscDevice.id`（`drutil list` 的 1 基序号）表示用户明确选定了设备。
public protocol BurnService: Sendable {
    func listDevices() async throws -> [DiscDevice]
    func status(deviceID: String?) async throws -> DiscStatus
    func burnAudio(trackURL: URL, deviceID: String?) async throws
    func burnImage(imageURL: URL, deviceID: String?) async throws
    func eject(deviceID: String?) async throws
}

// MARK: - 命令行抽象

/// 允许调用的系统工具（只允许这两个，HANDOFF §3.2）。
public enum BurnTool: String, Sendable, CaseIterable {
    case drutil
    case hdiutil

    public var executablePath: String {
        switch self {
        case .drutil: return "/usr/bin/drutil"
        case .hdiutil: return "/usr/bin/hdiutil"
        }
    }
}

/// 一条待执行的命令。
///
/// 这是纯数据：命令构造（`BurnCommandBuilder`）与执行（`CommandExecutor`）分开，
/// 前者可以在没有光驱、甚至没有 macOS 的 CI 上做单元测试。`timeoutSeconds`、
/// `writesDisc` 也属于命令规格的一部分——查询类命令超时应短，刻录类命令超时
/// 很长，而且只有真正写盘的命令才需要「盘片可能报废」的提示。
public struct BurnCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    /// 超时秒数（nil = 不设超时）。
    public let timeoutSeconds: TimeInterval?
    /// 这条命令是否会往盘上写数据（决定取消/超时的措辞）。
    public let writesDisc: Bool

    public init(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval? = nil,
        writesDisc: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
        self.writesDisc = writesDisc
    }

    /// 可以贴进日志/错误对话框的完整命令（自动给含空格的参数加单引号）。
    public var displayString: String {
        ([executable] + arguments.map(BurnCommand.shellQuote)).joined(separator: " ")
    }

    /// 只做展示用的最小 shell 引用，不负责执行。
    public static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_+=:,./-")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// 子进程的执行结果。
public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { exitCode == 0 }

    /// 解析用：drutil 有时把信息写到 stderr，两个流都看才稳。
    public var combinedOutput: String {
        if standardError.isEmpty { return standardOutput }
        if standardOutput.isEmpty { return standardError }
        return standardOutput + "\n" + standardError
    }
}

// MARK: - 执行器

/// 命令执行器。抽成协议是为了让 `DrutilBurner` 的逻辑（预检、错误翻译、
/// 取消措辞）能在**没有光驱、也不启动任何子进程**的单元测试里跑通。
public protocol CommandExecutor: Sendable {
    /// 执行一条命令。`onOutputLine` 会按行回调 stdout（用于进度解析）。
    func run(_ command: BurnCommand, onOutputLine: (@Sendable (String) -> Void)?) async throws -> CommandResult
}

public extension CommandExecutor {
    func run(_ command: BurnCommand) async throws -> CommandResult {
        try await run(command, onOutputLine: nil)
    }
}

/// 真机执行器：用 `Process` 跑 `/usr/bin/drutil`、`/usr/bin/hdiutil`。
///
/// 实现要点：
/// - 不阻塞等待 `waitUntilExit()`，而是轮询 `isRunning`，这样任务被取消时能
///   立刻终止子进程（否则用户点「取消」要等刻录跑完才生效）；
/// - stdout/stderr 各用一个 `readabilityHandler` 持续抽干，避免管道写满把
///   子进程卡死；
/// - 超时先 `SIGTERM`，3 秒内不退再 `SIGKILL`。
public struct SystemCommandExecutor: CommandExecutor {
    public init() {}

    public func run(
        _ command: BurnCommand,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: command.executable) else {
            throw BurnError.commandMissing(command.executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputCollector = TextLineCollector(onLine: onOutputLine)
        let errorCollector = TextLineCollector(onLine: nil)
        let eofTracker = StreamCloseTracker(streamCount: 2)

        do {
            try process.run()
        } catch {
            throw BurnError.toolFailed(
                command: command.displayString,
                exitCode: -1,
                output: error.localizedDescription
            )
        }

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                eofTracker.signal()
            } else {
                outputCollector.ingest(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                eofTracker.signal()
            } else {
                errorCollector.ingest(data)
            }
        }

        let started = Date()
        var timedOut = false
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if let timeout = command.timeoutSeconds,
                   Date().timeIntervalSince(started) > timeout {
                    timedOut = true
                    terminate(process)
                    break
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        } catch {
            // 取消：先把子进程收掉，再把 CancellationError 交给上层翻译。
            terminate(process)
            await waitForStreamsToClose(eofTracker, timeout: 3)
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        if process.isRunning { terminate(process) }
        await waitForStreamsToClose(eofTracker, timeout: 5)
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        if timedOut, let timeout = command.timeoutSeconds {
            throw BurnError.timedOut(seconds: timeout, discMayBeDamaged: command.writesDisc)
        }

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: outputCollector.finish(),
            standardError: errorCollector.finish()
        )
    }

    /// 等两个管道读到 EOF。子进程已经退出，EOF 通常几毫秒就到；这里用轮询而
    /// 不是 `DispatchGroup.wait`，因为后者在 async 上下文里会被 Swift 6 警告。
    private func waitForStreamsToClose(_ tracker: StreamCloseTracker, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !tracker.isClosed, Date() < deadline {
            // sleep 在任务被取消时会立刻抛错，此时不再等：上层马上会重抛取消。
            guard (try? await Task.sleep(nanoseconds: 10_000_000)) != nil else { return }
        }
    }

    /// 先礼后兵：`SIGTERM` → 最多等 3 秒 → `SIGKILL`。
    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

/// 统计「几路管道已经读到 EOF」。
final class StreamCloseTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let streamCount: Int
    private var closedStreams = 0

    init(streamCount: Int) {
        self.streamCount = streamCount
    }

    func signal() {
        lock.lock()
        closedStreams += 1
        lock.unlock()
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closedStreams >= streamCount
    }
}

/// 按行切分输出（同时接受 `\n` 与 `\r`：有些进度输出只用回车覆盖同一行）。
final class TextLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var collected = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        var emitted: [String] = []
        lock.lock()
        pending.append(data)
        while let separator = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = pending[pending.startIndex..<separator]
            pending.removeSubrange(pending.startIndex...separator)
            if let text = String(data: lineData, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    emitted.append(trimmed)
                    collected += trimmed + "\n"
                }
            }
        }
        lock.unlock()
        guard let onLine else { return }
        for line in emitted { onLine(line) }
    }

    /// 收尾：把没有换行结尾的最后一小块也算进去。
    func finish() -> String {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty, let text = String(data: pending, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { collected += trimmed + "\n" }
        }
        pending.removeAll()
        return collected
    }
}
