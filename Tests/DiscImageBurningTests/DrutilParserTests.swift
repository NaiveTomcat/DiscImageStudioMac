import XCTest
@testable import DiscImageBurning

/// 输出解析的单元测试。
///
/// 样本说明：本机没有刻录机，`drutil list` 在这里只会打印表头（样本 1 就是这台
/// 机器的真实输出）。其余样本按 `drutil(1)` 的栏目名与公开记录的输出形态构造，
/// 覆盖「有设备 / 无设备 / 空白盘 / 非空白盘 / 无盘」五种情况。
final class DrutilParserTests: XCTestCase {

    // MARK: - drutil list 样本

    /// 这台机器（无刻录机）的真实输出：只有表头。
    static let emptyDeviceTable = """
       Vendor   Product           Rev      Bus       SupportLevel

    """

    /// 两台设备，列宽与系统真实表头对齐（产品名里故意留双空格）。
    static let twoDevices = """
       Vendor   Product           Rev      Bus       SupportLevel
       HL-DT-ST BD-RE  WH16NS40   1.02     USB       cd-r,cd-rw,dvd-r,dvd-rw,bd-r,bd-re
       Apple    SuperDrive        2.00     USB       Unsupported
    """

    // MARK: - drutil list 解析

    func testNoDevicesYieldsEmptyList() {
        XCTAssertEqual(DrutilParser.parseDeviceList(Self.emptyDeviceTable), [])
        XCTAssertEqual(DrutilParser.parseDeviceList(""), [])
    }

    func testParsesTwoDevicesAlignedByHeaderColumns() {
        let devices = DrutilParser.parseDeviceList(Self.twoDevices)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].id, "1")
        XCTAssertEqual(devices[0].vendor, "HL-DT-ST")
        // 产品名里的双空格必须保留：按空白切会把它切成两个字段。
        XCTAssertEqual(devices[0].product, "BD-RE  WH16NS40")
        XCTAssertEqual(devices[0].bus, "USB")
        XCTAssertEqual(devices[0].supportLevel, "cd-r,cd-rw,dvd-r,dvd-rw,bd-r,bd-re")
        XCTAssertEqual(devices[1].id, "2")
        XCTAssertEqual(devices[1].vendor, "Apple")
        XCTAssertEqual(devices[1].product, "SuperDrive")
        XCTAssertEqual(devices[1].displayName, "Apple SuperDrive（USB）")
        XCTAssertTrue(devices[0].supportsAnyRecordableMedia())
        XCTAssertFalse(devices[1].supportsAnyRecordableMedia())
    }

    func testParsesDeviceRowWithLeadingIndexColumn() {
        // 某些 macOS 版本在行首多打一列序号；此时表头列宽对不上，要走兜底切分。
        let output = """
           Vendor   Product           Rev      Bus       SupportLevel
           1        Apple             SuperDrive  2.00   USB   cd-r,cd-rw
        """
        let devices = DrutilParser.parseDeviceList(output)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].vendor, "Apple")
        XCTAssertEqual(devices[0].product, "SuperDrive")
        XCTAssertEqual(devices[0].bus, "USB")
        XCTAssertEqual(devices[0].supportLevel, "cd-r,cd-rw")
    }

    func testTokenizeFallsBackToSingleSpaceColumns() {
        // 真实输出里单空格分隔的形态（论坛记录）：vendor 一个词，rev/bus/support 从右数。
        let fields = DrutilParser.tokenize("MATSHITA DVD-R UJ-845 DBN9 ATAPI Supported")
        XCTAssertEqual(fields?.vendor, "MATSHITA")
        XCTAssertEqual(fields?.product, "DVD-R UJ-845")
        XCTAssertEqual(fields?.rev, "DBN9")
        XCTAssertEqual(fields?.bus, "ATAPI")
        XCTAssertEqual(fields?.supportLevel, "Supported")
    }

    func testTokenizeRejectsGarbage() {
        XCTAssertNil(DrutilParser.tokenize(""))
        XCTAssertNil(DrutilParser.tokenize("   "))
        XCTAssertNil(DrutilParser.tokenize("only one"))
    }

    // MARK: - drutil status 样本

    static let blankCDStatus = """
       Vendor   Product           Rev
       Apple    SuperDrive        2.00

    Type: CD-R
    Name: /dev/disk4
    Curve Write Speed: 24x
    Space Free: 79:58:74   blocks: 359845 / 736.96MB / 702.82MiB
    Space Used: 00:00:00   blocks: 0 / 0.00MB / 0.00MiB
    Writability: blank
    """

    /// 值折到下一行的形态（公开记录里的 DVD+R DL 空白盘）。
    static let blankDVDPlusRWrapped = """
       Vendor   Product           Rev
       SONY     DVD RW DRU-840A   SS00

    Type: DVD+R DL
    Name: /dev/disk4
    Write Speeds: 4x, 6x, 8x
    Overwritable:
       927:30:74         blocks:  4173824 /   8.55GB /   7.96GiB
    Space Free:
       927:30:74         blocks:  4173824 /   8.55GB /   7.96GiB
    Space Used:
       00:00:00         blocks:        0 /   0.00MB /   0.00MiB
    Layer 0:
                        blocks:  2086912 /   4.27GB /   3.98GiB
    Writability: appendable, blank, overwritable
    Book Type: DVD+R DL (v1)
    Media ID: RITEK S04
    """

    static let usedDVDRStatus = """
    Type: DVD-R
    Name: /dev/disk4
    Space Free: 00:00:00   blocks: 0 / 0.00MB / 0.00MiB
    Space Used: 00:00:00   blocks: 2295104 / 4.70GB / 4.38GiB
    Writability: read-only
    """

    static let noMediaStatus = """
    Type: No Media Inserted
    Name: /dev/disk4
    """

    func testParsesBlankCDStatus() throws {
        let status = try DrutilParser.parseStatus(Self.blankCDStatus)
        XCTAssertTrue(status.isBlank)
        XCTAssertEqual(status.mediaType, "CD-R")
        XCTAssertTrue(status.isWritable)
        XCTAssertEqual(status.freeBytes, 359_845 * 2048)
        XCTAssertEqual(status.capacityBytes, 359_845 * 2048)
        XCTAssertEqual(status.usedBytes, 0)
    }

    func testParsesWrappedStatusFields() throws {
        let status = try DrutilParser.parseStatus(Self.blankDVDPlusRWrapped)
        XCTAssertTrue(status.isBlank)
        XCTAssertEqual(status.mediaType, "DVD+R DL")
        XCTAssertTrue(status.isWritable)
        XCTAssertEqual(status.capacityBytes, 4_173_824 * 2048)
        XCTAssertEqual(status.freeBytes, 4_173_824 * 2048)
        XCTAssertEqual(status.usedFraction, 0)
    }

    func testParsesNonBlankDVDAsNotWritable() throws {
        let status = try DrutilParser.parseStatus(Self.usedDVDRStatus)
        XCTAssertFalse(status.isBlank)
        XCTAssertFalse(status.isWritable)
        XCTAssertEqual(status.mediaType, "DVD-R")
        XCTAssertEqual(status.freeBytes, 0)
        XCTAssertEqual(status.capacityBytes, 2_295_104 * 2048)
        XCTAssertEqual(status.usedFraction ?? 0, 1.0, accuracy: 1e-9)
    }

    /// 把「解析失败」收成一个 `BurnError`，省掉每处都写一遍 `XCTAssertThrowsError`。
    private func statusError(_ output: String) -> BurnError? {
        do {
            _ = try DrutilParser.parseStatus(output)
            return nil
        } catch {
            return error as? BurnError
        }
    }

    func testNoMediaIsReportedAsNoMedia() {
        guard let error = statusError(Self.noMediaStatus) else {
            return XCTFail("期望抛错")
        }
        guard case .noMedia = error else {
            return XCTFail("期望 noMedia，实际 \(error)")
        }
    }

    func testEmptyStatusOutputMeansNoDevice() {
        // 没有刻录机时 `drutil status` 输出为空、退出码 0（本机实测）。
        guard let error = statusError("") else { return XCTFail("期望抛错") }
        guard case .noDevice = error else { return XCTFail("期望 noDevice，实际 \(error)") }
    }

    func testUnrecognizedStatusOutputIsRejectedInsteadOfGuessed() {
        // 只有设备表、没有介质字段：宁可报「无法解析」，也不能猜成「空白盘」。
        guard let error = statusError(" Vendor   Product           Rev\n Apple    SuperDrive        2.00\n") else {
            return XCTFail("期望抛错")
        }
        guard case .unparsableStatus = error else {
            return XCTFail("期望 unparsableStatus，实际 \(error)")
        }
    }

    func testMediaTypeExtraction() {
        XCTAssertEqual(DrutilParser.mediaType(in: Self.usedDVDRStatus), "DVD-R")
        XCTAssertEqual(DrutilParser.mediaType(in: "nothing here"), "")
    }

    // MARK: - 容量解析

    func testBlocksBeatHumanReadableUnits() {
        XCTAssertEqual(DrutilParser.parseByteCount("blocks:  4173824 /   8.55GB"), 4_173_824 * 2048)
        XCTAssertEqual(DrutilParser.parseByteCount("blocks:        0 /   0.00MB"), 0)
        XCTAssertEqual(DrutilParser.parseByteCount("blocks: 359845"), 359_845 * 2048)
    }

    func testHumanReadableSizes() {
        XCTAssertEqual(DrutilParser.humanByteCount(in: "736.96MB"), 736_960_000)
        XCTAssertEqual(DrutilParser.humanByteCount(in: "702.82MiB"), Int64((702.82 * 1_048_576).rounded()))
        XCTAssertEqual(DrutilParser.humanByteCount(in: "8.55GB"), 8_550_000_000)
        XCTAssertNil(DrutilParser.humanByteCount(in: "927:30:74"))
        XCTAssertNil(DrutilParser.humanByteCount(in: "没有数字"))
    }

    // MARK: - 进度解析

    func testProgressFromPercentLines() throws {
        let writing = try XCTUnwrap(DrutilParser.parseProgress("Burning: 42.0% complete"))
        XCTAssertEqual(writing.stage, .writing)
        XCTAssertEqual(try XCTUnwrap(writing.fraction), 0.42, accuracy: 1e-9)
        XCTAssertEqual(writing.percentText, "42%")

        let verifying = try XCTUnwrap(DrutilParser.parseProgress("Verifying: 100%"))
        XCTAssertEqual(verifying.stage, .verifying)
        XCTAssertEqual(try XCTUnwrap(verifying.fraction), 1.0, accuracy: 1e-9)

        // 只有百分比、没有动词的形态（省略号式进度）。
        let bare = try XCTUnwrap(DrutilParser.parseProgress(" ......... 12.5 % ...."))
        XCTAssertEqual(bare.stage, .writing)
        XCTAssertEqual(try XCTUnwrap(bare.fraction), 0.125, accuracy: 1e-9)
    }

    func testProgressStageKeywords() {
        XCTAssertEqual(DrutilParser.parseProgress("Preparing to burn…")?.stage, .preparing)
        XCTAssertEqual(DrutilParser.parseProgress("Finalizing disc")?.stage, .finishing)
        XCTAssertEqual(DrutilParser.parseProgress("Burn failed: sense code 03/0C")?.stage, .failed)
    }

    func testProgressIgnoresNoise() {
        XCTAssertNil(DrutilParser.parseProgress(""))
        XCTAssertNil(DrutilParser.parseProgress("Media ID: RITEK S04"))
        XCTAssertNil(DrutilParser.parseProgress("Type: CD-R"))
    }

    func testPercentageIgnoresOutOfRangeValues() {
        XCTAssertNil(DrutilParser.percentage(in: "增长 120%"))
        XCTAssertNil(DrutilParser.percentage(in: "没有百分号"))
    }

    // MARK: - 失败分类

    private func result(_ output: String, exitCode: Int32 = 1) -> CommandResult {
        CommandResult(exitCode: exitCode, standardOutput: "", standardError: output)
    }

    private let command = BurnCommand(executable: "/usr/bin/drutil", arguments: ["burn"])

    func testClassifiesMissingDevice() {
        let error = DrutilParser.failure(
            for: result("Could not find a valid device."),
            command: command
        )
        XCTAssertEqual(error, .noDevice)
    }

    func testClassifiesNoMedia() {
        XCTAssertEqual(
            DrutilParser.failure(for: result("No Media Inserted"), command: command),
            .noMedia(device: nil)
        )
    }

    func testClassifiesNotBlankWithMediaType() {
        let error = DrutilParser.failure(
            for: result("Type: DVD-R\nThe medium is not blank."),
            command: command
        )
        XCTAssertEqual(error, .discNotBlank(mediaType: "DVD-R"))
    }

    func testClassifiesPermissionDeniedAndBusy() {
        guard case .permissionDenied = DrutilParser.failure(
            for: result("Permission denied"), command: command
        ) else { return XCTFail("期望 permissionDenied") }

        guard case .deviceBusy = DrutilParser.failure(
            for: result("The device is busy."), command: command
        ) else { return XCTFail("期望 deviceBusy") }
    }

    func testClassifiesCapacityProblem() {
        guard case .insufficientCapacity = DrutilParser.failure(
            for: result("Not enough space on media"), command: command
        ) else { return XCTFail("期望 insufficientCapacity") }
    }

    func testUnknownFailureKeepsCommandAndTail() {
        let error = DrutilParser.failure(
            for: result("first line\nsecond line\nstrange failure\nlast line"),
            command: command
        )
        guard case .toolFailed(let commandText, let exitCode, let output) = error else {
            return XCTFail("期望 toolFailed，实际 \(error)")
        }
        XCTAssertEqual(exitCode, 1)
        XCTAssertEqual(commandText, "/usr/bin/drutil burn")
        XCTAssertTrue(output.contains("last line"))
        XCTAssertFalse(output.contains("first line"), "只保留最后几行，避免弹窗被刷屏")
    }
}
