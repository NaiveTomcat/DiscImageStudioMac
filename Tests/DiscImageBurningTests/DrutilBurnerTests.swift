import XCTest
@testable import DiscImageBurning

/// 假执行器：记录命令、按脚本返回输出。**不启动任何子进程**，所以可以在没有
/// 光驱的机器和 CI 上跑，也不会误伤真实盘片。
final class FakeExecutor: CommandExecutor, @unchecked Sendable {
    typealias Handler = @Sendable (BurnCommand, (@Sendable (String) -> Void)?) throws -> CommandResult

    private let lock = NSLock()
    private var recorded: [BurnCommand] = []
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var commands: [BurnCommand] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(
        _ command: BurnCommand,
        onOutputLine: (@Sendable (String) -> Void)?
    ) async throws -> CommandResult {
        lock.lock()
        recorded.append(command)
        lock.unlock()
        return try handler(command, onOutputLine)
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BurnProgress] = []

    func append(_ progress: BurnProgress) {
        lock.lock()
        events.append(progress)
        lock.unlock()
    }

    var all: [BurnProgress] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

/// `DrutilBurner` 的行为测试：设备解析、预检、错误翻译、取消措辞、进度回调。
final class DrutilBurnerTests: XCTestCase {

    // MARK: - 样本

    private static let singleDevice = """
       Vendor   Product           Rev      Bus       SupportLevel
       Apple    SuperDrive        2.00     USB       cd-r,cd-rw,dvd-r,dvd-rw
    """

    private static let tinyBlankCD = """
    Type: CD-R
    Space Free: 00:01:00   blocks: 10 / 0.02MB / 0.02MiB
    Space Used: 00:00:00   blocks: 0 / 0.00MB / 0.00MiB
    Writability: blank
    """

    private func scriptedExecutor(
        devices: String = DrutilBurnerTests.singleDevice,
        status: String = DrutilParserTests.blankCDStatus,
        burnResult: CommandResult = CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
        burnLines: [String] = []
    ) -> FakeExecutor {
        FakeExecutor { command, onLine in
            if command.arguments.contains("list") {
                return CommandResult(exitCode: 0, standardOutput: devices, standardError: "")
            }
            if command.arguments.contains("status") {
                return CommandResult(exitCode: 0, standardOutput: status, standardError: "")
            }
            if command.arguments.contains("eject") {
                return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            }
            if command.arguments.contains("burn") {
                for line in burnLines { onLine?(line) }
                return burnResult
            }
            return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        }
    }

    private func makeTempFile(extension suffix: String, bytes: Int = 4096) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("discimage-burning-\(UUID().uuidString)")
            .appendingPathExtension(suffix)
        try Data(repeating: 0, count: bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func burnError(_ operation: () async throws -> Void) async -> BurnError? {
        do {
            try await operation()
            return nil
        } catch {
            return error as? BurnError
        }
    }

    // MARK: - 设备

    func testListDevices() async throws {
        let executor = scriptedExecutor()
        let burner = DrutilBurner(executor: executor)
        let devices = try await burner.listDevices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].vendor, "Apple")
        XCTAssertEqual(executor.commands.map(\.arguments), [["list"]])
    }

    func testStatusUsesSelectedDeviceWithoutListing() async throws {
        let executor = scriptedExecutor()
        let burner = DrutilBurner(executor: executor)
        let status = try await burner.status(deviceID: "2")
        XCTAssertTrue(status.isBlank)
        XCTAssertEqual(executor.commands.map(\.arguments), [["-drive", "2", "status"]])
    }

    func testStatusWithoutSelectionResolvesTheOnlyDevice() async throws {
        let executor = scriptedExecutor()
        let burner = DrutilBurner(executor: executor)
        _ = try await burner.status(deviceID: nil)
        XCTAssertEqual(
            executor.commands.map(\.arguments),
            [["list"], ["-drive", "1", "status"]]
        )
    }

    func testMultipleDevicesWithoutSelectionAreRejected() async {
        let executor = scriptedExecutor(devices: DrutilParserTests.twoDevices)
        let burner = DrutilBurner(executor: executor)
        let error = await burnError { _ = try await burner.status(deviceID: nil) }
        XCTAssertEqual(error, .ambiguousDevices(count: 2))
        // 只跑了 list，没有再往下走——绝不能对「所有光驱」执行刻录/查询。
        XCTAssertEqual(executor.commands.map(\.arguments), [["list"]])
    }

    func testNoDevicesMeansNoDevice() async {
        let executor = scriptedExecutor(devices: "")
        let burner = DrutilBurner(executor: executor)
        let error = await burnError { _ = try await burner.listDevices() }
        XCTAssertNil(error)
        let statusError = await burnError { _ = try await burner.status(deviceID: nil) }
        XCTAssertEqual(statusError, .noDevice)
    }

    func testInvalidDeviceIDIsRejectedBeforeAnyCommand() async {
        let executor = scriptedExecutor()
        let burner = DrutilBurner(executor: executor)
        let error = await burnError { _ = try await burner.status(deviceID: "usb") }
        guard case .invalidDeviceID = error else {
            return XCTFail("期望 invalidDeviceID，实际 \(String(describing: error))")
        }
        XCTAssertTrue(executor.commands.isEmpty)
    }

    // MARK: - 刻录音轨

    func testBurnAudioSuccessSendsAudioCommandAndReportsProgress() async throws {
        let executor = scriptedExecutor(
            burnLines: ["Burning: 10.0% complete", "Burning: 100%", "Done"]
        )
        let progress = ProgressBox()
        let burner = DrutilBurner(executor: executor, progress: { progress.append($0) })
        let track = try makeTempFile(extension: "wav")

        try await burner.burnAudio(trackURL: track, deviceID: "1")

        let commands = executor.commands.map(\.arguments)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0], ["-drive", "1", "status"])
        XCTAssertEqual(commands[1], ["-drive", "1", "burn", "-audio", "-noverify", track.path])

        let events = progress.all
        XCTAssertGreaterThanOrEqual(events.count, 3)
        XCTAssertEqual(events.first?.stage, .writing)
        XCTAssertEqual(events.last?.stage, .completed)
        XCTAssertEqual(events.last?.fraction, 1)
    }

    func testBurnAudioRefusesNonBlankDisc() async throws {
        let executor = scriptedExecutor(status: DrutilParserTests.usedDVDRStatus)
        let burner = DrutilBurner(executor: executor)
        let track = try makeTempFile(extension: "wav")

        let error = await burnError { try await burner.burnAudio(trackURL: track, deviceID: "1") }
        XCTAssertEqual(error, .discNotBlank(mediaType: "DVD-R"))
        // 预检失败就不该有 burn 命令——否则会白毁一张盘。
        XCTAssertFalse(executor.commands.contains { $0.arguments.contains("burn") })
        XCTAssertTrue(error?.recoverySuggestion?.contains("空白") == true)
    }

    func testBurnAudioRejectsInsufficientCapacity() async throws {
        let executor = scriptedExecutor(status: Self.tinyBlankCD)
        let burner = DrutilBurner(executor: executor)
        let track = try makeTempFile(extension: "wav", bytes: 65_536)

        let error = await burnError { try await burner.burnAudio(trackURL: track, deviceID: "1") }
        XCTAssertEqual(
            error,
            .insufficientCapacity(requiredBytes: 65_536, availableBytes: 20_480)
        )
        XCTAssertFalse(executor.commands.contains { $0.arguments.contains("burn") })
    }

    func testBurnAudioRejectsUnsupportedFileType() async throws {
        let executor = scriptedExecutor()
        let burner = DrutilBurner(executor: executor)
        let image = try makeTempFile(extension: "iso")

        let error = await burnError { try await burner.burnAudio(trackURL: image, deviceID: "1") }
        guard case .unsupportedMedia = error else {
            return XCTFail("期望 unsupportedMedia，实际 \(String(describing: error))")
        }
        XCTAssertTrue(executor.commands.isEmpty)
    }

    func testBurnAudioRejectsMissingFile() async {
        let executor = scriptedExecutor()
        let burner = DrutilBurner(executor: executor)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("discimage-burning-missing-\(UUID().uuidString).wav")

        let error = await burnError { try await burner.burnAudio(trackURL: missing, deviceID: "1") }
        guard case .missingFile = error else {
            return XCTFail("期望 missingFile，实际 \(String(describing: error))")
        }
        XCTAssertTrue(executor.commands.isEmpty)
    }

    // MARK: - 数据盘

    func testBurnImageUsesDrutilByDefault() async throws {
        let executor = scriptedExecutor()
        let burner = DrutilBurner(executor: executor)
        let image = try makeTempFile(extension: "iso")

        try await burner.burnImage(imageURL: image, deviceID: "1")

        XCTAssertEqual(
            executor.commands.last?.arguments,
            ["-drive", "1", "burn", "-noverify", image.path]
        )
        XCTAssertEqual(executor.commands.last?.executable, "/usr/bin/drutil")
    }

    func testBurnImageCanUseHdiutil() async throws {
        let executor = scriptedExecutor()
        let burner = DrutilBurner(executor: executor, imageTool: .hdiutil)
        let image = try makeTempFile(extension: "iso")

        try await burner.burnImage(imageURL: image, deviceID: nil)

        XCTAssertEqual(executor.commands.last?.executable, "/usr/bin/hdiutil")
        XCTAssertEqual(executor.commands.last?.arguments, ["burn", "-noverifyburn", image.path])
    }

    func testEjectResolvesDevice() async throws {
        let executor = scriptedExecutor()
        let burner = DrutilBurner(executor: executor)
        try await burner.eject(deviceID: nil)
        XCTAssertEqual(executor.commands.last?.arguments, ["-drive", "1", "eject"])
    }

    // MARK: - 取消 / 超时 / 失败翻译

    func testCancellationDuringBurnWarnsAboutDamagedDisc() async throws {
        let track = try makeTempFile(extension: "wav")
        let executor = FakeExecutor { command, _ in
            if command.arguments.contains("burn") { throw CancellationError() }
            if command.arguments.contains("status") {
                return CommandResult(exitCode: 0, standardOutput: DrutilParserTests.blankCDStatus, standardError: "")
            }
            return CommandResult(exitCode: 0, standardOutput: Self.singleDevice, standardError: "")
        }
        let burner = DrutilBurner(executor: executor)

        let error = await burnError { try await burner.burnAudio(trackURL: track, deviceID: "1") }
        XCTAssertEqual(error, .cancelled(discMayBeDamaged: true))
        XCTAssertTrue(error?.errorDescription?.contains("盘片可能") == true)
    }

    func testCancellationDuringPreflightDoesNotDamageDisc() async throws {
        let track = try makeTempFile(extension: "wav")
        let executor = FakeExecutor { command, _ in
            if command.arguments.contains("status") { throw CancellationError() }
            return CommandResult(exitCode: 0, standardOutput: Self.singleDevice, standardError: "")
        }
        let burner = DrutilBurner(executor: executor)

        let error = await burnError { try await burner.burnAudio(trackURL: track, deviceID: "1") }
        XCTAssertEqual(error, .cancelled(discMayBeDamaged: false))
        XCTAssertFalse(error?.discMayBeDamaged == true)
    }

    func testBurnFailureIsClassified() async throws {
        let track = try makeTempFile(extension: "wav")
        let executor = scriptedExecutor(
            burnResult: CommandResult(exitCode: 1, standardOutput: "", standardError: "Permission denied")
        )
        let burner = DrutilBurner(executor: executor)

        let error = await burnError { try await burner.burnAudio(trackURL: track, deviceID: "1") }
        guard case .permissionDenied = error else {
            return XCTFail("期望 permissionDenied，实际 \(String(describing: error))")
        }
    }

    func testTimeoutIsTranslated() async throws {
        let track = try makeTempFile(extension: "wav")
        let executor = FakeExecutor { command, _ in
            if command.arguments.contains("burn") {
                throw BurnError.timedOut(seconds: 60, discMayBeDamaged: true)
            }
            if command.arguments.contains("status") {
                return CommandResult(exitCode: 0, standardOutput: DrutilParserTests.blankCDStatus, standardError: "")
            }
            return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let burner = DrutilBurner(executor: executor)

        let error = await burnError { try await burner.burnAudio(trackURL: track, deviceID: "1") }
        XCTAssertEqual(error, .timedOut(seconds: 60, discMayBeDamaged: true))
        XCTAssertTrue(error?.discMayBeDamaged == true)
    }

    func testMissingCommandIsTranslated() async {
        let executor = FakeExecutor { _, _ in
            throw BurnError.commandMissing("/usr/bin/drutil")
        }
        let burner = DrutilBurner(executor: executor)
        let error = await burnError { _ = try await burner.listDevices() }
        XCTAssertEqual(error, .commandMissing("/usr/bin/drutil"))
    }

    // MARK: - Mock

    func testMockBurnServiceRecordsCalls() async throws {
        let mock = MockBurnService()
        let devices = try await mock.listDevices()
        XCTAssertEqual(devices.count, 2)
        let status = try await mock.status(deviceID: "1")
        XCTAssertTrue(status.isBlank)
        let track = URL(fileURLWithPath: "/tmp/cover.wav")
        try await mock.burnAudio(trackURL: track, deviceID: "1")
        try await mock.eject(deviceID: "1")

        XCTAssertEqual(
            mock.calls,
            [
                .listDevices,
                .status(deviceID: "1"),
                .burnAudio(trackURL: track, deviceID: "1"),
                .eject(deviceID: "1"),
            ]
        )
        mock.resetCalls()
        XCTAssertTrue(mock.calls.isEmpty)
    }

    func testMockBurnServiceWithoutDevices() async {
        let mock = MockBurnService.noDevice
        let error = await burnError { _ = try await mock.status(deviceID: nil) }
        XCTAssertEqual(error, .noDevice)
    }

    func testMockBurnServiceInjectsFailure() async {
        let mock = MockBurnService(failure: .discNotBlank(mediaType: "DVD-R"))
        let error = await burnError {
            try await mock.burnImage(imageURL: URL(fileURLWithPath: "/tmp/x.iso"), deviceID: nil)
        }
        XCTAssertEqual(error, .discNotBlank(mediaType: "DVD-R"))
    }

    func testMockBurnServiceCancellation() async {
        let mock = MockBurnService(burnDelayNanoseconds: 5_000_000_000)
        let task = Task {
            try await mock.burnImage(imageURL: URL(fileURLWithPath: "/tmp/x.iso"), deviceID: nil)
        }
        task.cancel()
        do {
            try await task.value
        } catch is CancellationError {
            // 预期：Mock 会尊重取消，界面能立刻回到可操作状态。
        } catch {
            XCTFail("期望 CancellationError，实际 \(error)")
        }
    }
}
