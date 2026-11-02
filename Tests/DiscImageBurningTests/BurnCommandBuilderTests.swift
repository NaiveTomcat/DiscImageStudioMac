import XCTest
@testable import DiscImageBurning

/// 命令构造的单元测试：不启动任何子进程，也不碰光驱。
///
/// 重点回归两条 man page 约定：
/// - `-drive` 必须出现在动词之前；
/// - 只有真正写盘的命令才带「盘片可能报废」语义（`writesDisc`）。
final class BurnCommandBuilderTests: XCTestCase {

    // MARK: - drutil 查询

    func testDeviceListCommand() {
        let command = BurnCommandBuilder.list()
        XCTAssertEqual(command.executable, "/usr/bin/drutil")
        XCTAssertEqual(command.arguments, ["list"])
        XCTAssertEqual(command.timeoutSeconds, BurnCommandBuilder.queryTimeoutSeconds)
        XCTAssertFalse(command.writesDisc)
    }

    func testStatusCommandPlacesDriveSelectionBeforeVerb() throws {
        let command = try BurnCommandBuilder.status(deviceID: "2")
        XCTAssertEqual(command.arguments, ["-drive", "2", "status"])
        XCTAssertEqual(command.timeoutSeconds, BurnCommandBuilder.queryTimeoutSeconds)
        let driveIndex = try XCTUnwrap(command.arguments.firstIndex(of: "-drive"))
        let verbIndex = try XCTUnwrap(command.arguments.firstIndex(of: "status"))
        XCTAssertLessThan(driveIndex, verbIndex)
    }

    func testStatusCommandWithoutDeviceHasNoDriveFlag() throws {
        let command = try BurnCommandBuilder.status(deviceID: nil)
        XCTAssertEqual(command.arguments, ["status"])
    }

    func testEjectCommand() throws {
        let command = try BurnCommandBuilder.eject(deviceID: "1")
        XCTAssertEqual(command.arguments, ["-drive", "1", "eject"])
        XCTAssertFalse(command.writesDisc)
    }

    // MARK: - 音频刻录

    func testBurnAudioCommandForWAVTrack() throws {
        let track = URL(fileURLWithPath: "/Users/tester/Exports/cover.wav")
        let command = try BurnCommandBuilder.burnAudio(trackURL: track, deviceID: "1")
        XCTAssertEqual(command.executable, "/usr/bin/drutil")
        XCTAssertEqual(command.arguments, ["-drive", "1", "burn", "-audio", "-noverify", track.path])
        XCTAssertTrue(command.writesDisc)
        XCTAssertEqual(command.timeoutSeconds, BurnCommandBuilder.defaultBurnTimeoutSeconds)
    }

    func testBurnAudioCommandForCueSheetOmitsAudioFlag() throws {
        // .cue 属于镜像文件（drutil(1) 明确列出 .cue/bin），不能加 -audio。
        let cue = URL(fileURLWithPath: "/Users/tester/Exports/cover.cue")
        let command = try BurnCommandBuilder.burnAudio(trackURL: cue, deviceID: "1")
        XCTAssertEqual(command.arguments, ["-drive", "1", "burn", "-noverify", cue.path])
        XCTAssertFalse(command.arguments.contains("-audio"))
    }

    func testBurnAudioRespectsVerifyAndEjectOptions() throws {
        let track = URL(fileURLWithPath: "/tmp/cover.wav")
        let command = try BurnCommandBuilder.burnAudio(
            trackURL: track,
            deviceID: "3",
            verify: true,
            eject: false
        )
        XCTAssertEqual(command.arguments, ["-drive", "3", "burn", "-audio", "-noeject", track.path])
        XCTAssertFalse(command.arguments.contains("-noverify"))
    }

    // MARK: - 数据盘刻录

    func testBurnImageWithDrutil() throws {
        let image = URL(fileURLWithPath: "/Users/tester/Exports/pattern.iso")
        let command = try BurnCommandBuilder.burnImage(imageURL: image, deviceID: "2")
        XCTAssertEqual(command.executable, "/usr/bin/drutil")
        XCTAssertEqual(command.arguments, ["-drive", "2", "burn", "-noverify", image.path])
        XCTAssertTrue(command.writesDisc)
    }

    func testBurnImageWithHdiutilUsesHdiutilFlags() throws {
        let image = URL(fileURLWithPath: "/Users/tester/Exports/pattern.iso")
        let command = try BurnCommandBuilder.burnImage(
            imageURL: image,
            deviceID: nil,
            tool: .hdiutil,
            verify: false,
            eject: false
        )
        XCTAssertEqual(command.executable, "/usr/bin/hdiutil")
        XCTAssertEqual(command.arguments, ["burn", "-noverifyburn", "-noeject", image.path])
        XCTAssertTrue(command.writesDisc)
    }

    func testHdiutilRejectsDrutilDriveIndex() {
        // hdiutil 的 -device 要的是 OpenFirmware 路径，不是 drutil 的序号；
        // 与其猜，不如直接报错，避免刻到错误的光驱。
        XCTAssertThrowsError(
            try BurnCommandBuilder.burnImage(
                imageURL: URL(fileURLWithPath: "/tmp/x.iso"),
                deviceID: "1",
                tool: .hdiutil
            )
        ) { error in
            guard let burnError = error as? BurnError else {
                return XCTFail("期望 BurnError，实际 \(error)")
            }
            guard case .invalidDeviceID = burnError else {
                return XCTFail("期望 invalidDeviceID，实际 \(burnError)")
            }
        }
    }

    // MARK: - 设备标识校验

    func testDriveIndexValidation() throws {
        XCTAssertEqual(try BurnCommandBuilder.validatedDriveIndex(" 3 "), "3")
        XCTAssertThrowsError(try BurnCommandBuilder.validatedDriveIndex("0"))
        XCTAssertThrowsError(try BurnCommandBuilder.validatedDriveIndex("-1"))
        XCTAssertThrowsError(try BurnCommandBuilder.validatedDriveIndex("usb"))
        XCTAssertThrowsError(try BurnCommandBuilder.validatedDriveIndex(""))
    }

    // MARK: - 展示用命令

    func testDisplayStringQuotesPathsWithSpaces() {
        let command = BurnCommand(
            executable: "/usr/bin/drutil",
            arguments: ["-drive", "1", "burn", "/Users/Tom Dang/track.wav"]
        )
        XCTAssertEqual(
            command.displayString,
            "/usr/bin/drutil -drive 1 burn '/Users/Tom Dang/track.wav'"
        )
    }

    func testShellQuote() {
        XCTAssertEqual(BurnCommand.shellQuote("plain-1.2_x"), "plain-1.2_x")
        XCTAssertEqual(BurnCommand.shellQuote("a b"), "'a b'")
        XCTAssertEqual(BurnCommand.shellQuote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(BurnCommand.shellQuote(""), "''")
    }
}
