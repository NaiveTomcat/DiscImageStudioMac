import XCTest
import DiscImageCore
@testable import DiscImageBluRay

/// 编码链的数学不变量：布局、EDC、RS、扰码、17PP、ECC 交织、RUB 长度。
///
/// 口径说明：本机没有 .NET，无法与源项目逐字节对拍，所以这里验证的是标准里的
/// 恒等式与可独立复核的性质（校验子为零、RLL 约束、长度守恒），外加源项目文档
/// 记录的两个整簇统计值（3T = 265,136 / 6T = 116,575）。
final class EncodingChainTests: XCTestCase {
    // MARK: - 布局恒等式

    func testClusterLayoutIdentity() {
        // 32 × 2052 = 304 × 216：这是「32 扇区必须对齐」的算术原因。
        XCTAssertEqual(BluRaySpec.sectorsPerCluster * BluRaySpec.dataFrameBytes,
                       BluRaySpec.ldcCodewords * BluRaySpec.ldcDataBytes)
        XCTAssertEqual(32 * 2052, 304 * 216)
        XCTAssertEqual(BluRaySpec.dataBytesPerCluster, 65_664)
        XCTAssertEqual(BluRaySpec.payloadBytesPerCluster, 65_536)

        // 簇 = 958,272 通道位；RUB = 962,136 通道位。
        XCTAssertEqual(BluRaySpec.physicalClusterChannelBits, 958_272)
        XCTAssertEqual(BluRaySpec.physicalClusterChannelBits, 496 * 1_932)
        XCTAssertEqual(BluRaySpec.channelBitsPerRecordingUnit, 962_136)
        XCTAssertEqual(BluRaySpec.runInChannelBits + 496 * 1_932 + BluRaySpec.runOutChannelBits, 962_136)
        XCTAssertEqual(BluRaySpec.channelBitsPerRecordingUnit,
                       BluRaySpec.runInChannelBits + BluRaySpec.physicalClusterChannelBits + BluRaySpec.runOutChannelBits)

        // 入口处会跑一次 precondition 版断言，这里显式再调一次确认常量没被改坏。
        BluRaySpec.validateLayout()
    }

    // MARK: - EDC

    func testEDCFrameRemainderIsZero() throws {
        // 各种 payload 都必须满足：追加 4 字节 EDC 后，整个 2052 字节余数为 0。
        var payloads: [[UInt8]] = [
            [UInt8](repeating: 0, count: 2048),
            [UInt8](repeating: 0xFF, count: 2048),
            (0..<2048).map { UInt8($0 & 0xFF) },
        ]
        var generator = SplitMix64(seed: 0xBD_1A_2B_3C)
        payloads.append((0..<2048).map { _ in UInt8(truncatingIfNeeded: generator.next()) })
        for payload in payloads {
            let frame = try BluRayEDC.dataFrame(userData: payload)
            XCTAssertEqual(frame.count, 2052)
            XCTAssertEqual(BluRayEDC.remainder(frame), 0, "2052 字节 data frame 的多项式余数必须为 0")
            // 前 2048 字节原样保留，后 4 字节为大端 EDC。
            XCTAssertEqual(Array(frame[0..<2048]), payload)
            let stored = (UInt32(frame[2048]) << 24) | (UInt32(frame[2049]) << 16)
                | (UInt32(frame[2050]) << 8) | UInt32(frame[2051])
            XCTAssertEqual(stored, BluRayEDC.compute(payload))
        }
    }

    func testEDCIsSensitiveToEveryByte() throws {
        var payload = [UInt8](repeating: 0x5A, count: 2048)
        let baseline = BluRayEDC.compute(payload)
        payload[1024] ^= 0x01
        XCTAssertNotEqual(baseline, BluRayEDC.compute(payload))
    }

    // MARK: - Reed-Solomon

    func testLDCReedSolomonSyndromesAreZero() throws {
        var generator = SplitMix64(seed: 0x0B_D0_00_01)
        for trial in 0..<24 {
            let information = (0..<216).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            let parity = try BluRayReedSolomon.parity(information: information, parityLength: 32)
            XCTAssertEqual(parity.count, 32)
            let codeword = information + parity
            XCTAssertEqual(codeword.count, 248)
            let syndromes = BluRayReedSolomon.syndromes(codeword, parityLength: 32)
            XCTAssertTrue(syndromes.allSatisfy { $0 == 0 }, "第 \(trial) 组 RS(248,216) 校验子不为零：\(syndromes)")
        }
    }

    func testAddressReedSolomonSyndromesAreZero() throws {
        var generator = SplitMix64(seed: 0x0B_D0_00_02)
        for _ in 0..<64 {
            let information = (0..<5).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            let parity = try BluRayReedSolomon.parity(information: information, parityLength: 4)
            let codeword = information + parity
            XCTAssertEqual(codeword.count, 9)
            XCTAssertTrue(BluRayReedSolomon.isCodeword(codeword, parityLength: 4))
        }
        // 全零信息 → 全零校验（系统码的必然结果）。
        XCTAssertEqual(try BluRayReedSolomon.parity(information: [0, 0, 0, 0, 0], parityLength: 4), [0, 0, 0, 0])
    }

    func testReedSolomonRejectsCorruption() throws {
        let information = [UInt8](repeating: 0x11, count: 216)
        var codeword = information + (try BluRayReedSolomon.parity(information: information, parityLength: 32))
        XCTAssertTrue(BluRayReedSolomon.isCodeword(codeword, parityLength: 32))
        codeword[42] ^= 0x80
        XCTAssertFalse(BluRayReedSolomon.isCodeword(codeword, parityLength: 32))
    }

    // MARK: - 扰码

    func testScramblerMaskIsDeterministicAndInvolutive() {
        let psn: UInt32 = 0x0010_0000
        let mask = BluRayScrambler.mask(physicalSectorNumber: psn)
        XCTAssertEqual(mask.count, 2052)
        XCTAssertEqual(mask, BluRayScrambler.mask(physicalSectorNumber: psn))
        XCTAssertNotEqual(mask, BluRayScrambler.mask(physicalSectorNumber: psn + 32))

        let payload = (0..<2052).map { UInt8($0 & 0xFF) }
        let scrambled = BluRayScrambler.scrambled(payload, physicalSectorNumber: psn)
        XCTAssertEqual(BluRayScrambler.scrambled(scrambled, physicalSectorNumber: psn), payload)
        for index in 0..<payload.count {
            XCTAssertEqual(scrambled[index], payload[index] ^ mask[index])
        }
    }

    func testScramblerSeedUsesPsnBits19to5() {
        // 种子 = 0x8000 | (PSN >> 5 & 0x7fff)；PSN 的低 5 位不参与，所以 32 个扇区同掩码。
        for offset in 0..<32 {
            XCTAssertEqual(
                BluRayScrambler.mask(physicalSectorNumber: 0x0010_0000 + UInt32(offset)),
                BluRayScrambler.mask(physicalSectorNumber: 0x0010_0000)
            )
        }
    }

    // MARK: - 17PP

    func test17PPOutputLengthAndRLLConstraints() throws {
        var generator = SplitMix64(seed: 0x17_99_0001)
        for trial in 0..<32 {
            // 1268 位（634 个数据位对）正好是一帧；再加少量不同长度覆盖终止分支。
            let bitCount = [2, 4, 6, 8, 1268][trial % 5]
            let dataBits = (0..<bitCount).map { _ in UInt8(truncatingIfNeeded: generator.next() & 1) }
            let previous: UInt8 = trial % 2 == 0 ? 0 : 1
            let result = try BluRay17PP.encode(dataBits: dataBits, previousModulationBit: previous)
            XCTAssertEqual(result.modulationBits.count, bitCount / 2 * 3, "17PP 码率必须是 2:3")
            assertRLL17(result.modulationBits, context: "trial \(trial)")
            _ = try BluRay17PP.channelLevels(modulationBits: result.modulationBits)
        }
    }

    func test17PPSubstitutionBreaksRepeatedPattern() throws {
        // 110111 + 010xxxxx 触发 Figure 41 的替换：6 个数据位 → 001000000。
        let dataBits: [UInt8] = [1, 1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1]
        let result = try BluRay17PP.encode(dataBits: dataBits, previousModulationBit: 0)
        XCTAssertEqual(Array(result.modulationBits[0..<9]), [0, 0, 1, 0, 0, 0, 0, 0, 0])
        assertRLL17(result.modulationBits, context: "substitution")
    }

    // MARK: - Recording frame / RUB

    func testRecordingFrameAndRecordingUnitLengths() throws {
        let psn: UInt32 = BluRaySpec.firstLayer0PhysicalSector
        let userData = [UInt8](repeating: 0xAA, count: BluRaySpec.payloadBytesPerCluster)
        let rub = try BluRayRecordingUnit.encode(userData: userData, firstPhysicalSectorNumber: psn)
        XCTAssertEqual(rub.modulationBits.count, 962_136)
        XCTAssertEqual(rub.channelLevels.count, 962_136)
        XCTAssertEqual(rub.dcControlBits.count, 496 * 28)
        XCTAssertFalse(rub.includesGuard3)
        XCTAssertEqual(BluRayRecordingUnit.dataModulationBits(of: rub).count, 958_272)

        let withGuard3 = try BluRayRecordingUnit.encode(
            userData: userData,
            firstPhysicalSectorNumber: psn,
            appendGuard3: true
        )
        XCTAssertEqual(withGuard3.modulationBits.count, 962_136 + 540)
    }

    func testFrameSyncIs30BitsAndUsesSevenSignatures() throws {
        // 31 个地址单元位置只用到 7 种同步签名；位置由序列顺序区分，不是 31 个互异码字。
        XCTAssertEqual(BluRayRecordingFrame.syncSignatures.count, 7)
        XCTAssertEqual(BluRayRecordingFrame.syncSequence.count, 31)
        XCTAssertTrue(BluRayRecordingFrame.syncSequence.allSatisfy { $0 < 7 })
        var signatures = Set<[UInt8]>()
        for index in 0...30 {
            let sync = try BluRayRecordingFrame.createFrameSync(frameWithinAddressUnit: index)
            XCTAssertEqual(sync.count, 30)
            XCTAssertTrue(sync.allSatisfy { $0 <= 1 })
            signatures.insert(sync)
        }
        XCTAssertEqual(signatures.count, 7, "同步帧最多 7 种签名（31 个位置按序复用）")
        let terminated = try BluRayRecordingFrame.createFrameSync(
            frameWithinAddressUnit: 0,
            precedingFrameUsedTermination: true
        )
        XCTAssertNotEqual(terminated, try BluRayRecordingFrame.createFrameSync(frameWithinAddressUnit: 0))
    }

    // MARK: - ECC 交织自检

    func testECCMultiplexRestoresLDCAndBISCodewords() throws {
        var generator = SplitMix64(seed: 0xECC0_1234)
        let userData = (0..<BluRaySpec.payloadBytesPerCluster).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
        let psn: UInt32 = BluRaySpec.firstLayer0PhysicalSector
        let ecc = try BluRayECCEncoder.encode(userData: userData, firstPhysicalSectorNumber: psn)
        XCTAssertEqual(ecc.count, 76_880)

        let ldc = try BluRayECCEncoder.encodeLDCCluster(userData: userData, firstPhysicalSectorNumber: psn)
        XCTAssertEqual(ldc.count, 75_392)
        let bis = try BluRayECCEncoder.encodeBISCluster(firstPhysicalSectorNumber: psn)
        XCTAssertEqual(bis.count, 1_488)

        // 逆复用：496 × 155 必须还原成 LDC 的 496 × 152，外加每行 3 个 BIS 字节。
        for row in 0..<496 {
            for group in 0..<4 {
                let source = row * 152 + group * 38
                let destination = row * 155 + group * 39
                XCTAssertEqual(Array(ecc[destination..<(destination + 38)]),
                               Array(ldc[source..<(source + 38)]))
                if group < 3 {
                    XCTAssertEqual(ecc[destination + 38], bis[row * 3 + group])
                }
            }
        }

        // 逆交织 LDC：每个 (row, column) 还原成一个 RS(248,216) 码字，校验子为零。
        var deinterleaved = [UInt8](repeating: 0, count: 304 * 248)
        for column in 0..<304 {
            for row in 0..<248 {
                let outputRow = row * 2 + column % 2
                let outputColumn = (column / 2 + 152 - (row * 3) % 152) % 152
                deinterleaved[column * 248 + row] = ldc[outputRow * 152 + outputColumn]
            }
        }
        for column in 0..<304 {
            let codeword = Array(deinterleaved[(column * 248)..<((column + 1) * 248)])
            XCTAssertTrue(BluRayReedSolomon.isCodeword(codeword, parityLength: 32),
                          "LDC 第 \(column) 个码字校验子不为零")
        }

        // 逆交织 BIS：24 列 × 62 字节，每列一个 RS(62,30) 码字。
        var access = [UInt8](repeating: 0, count: 24 * 62)
        for column in 0..<24 {
            for row in 0..<62 {
                let unit = (row / 2 + 8 - column / 3) % 8 + 8 * (row % 2)
                let unitRow = row / 2
                let outputColumn = (column + unitRow) % 3
                access[column * 62 + row] = bis[(unit * 31 + unitRow) * 3 + outputColumn]
            }
        }
        for column in 0..<24 {
            let codeword = Array(access[(column * 62)..<((column + 1) * 62)])
            XCTAssertTrue(BluRayReedSolomon.isCodeword(codeword, parityLength: 32),
                          "BIS 第 \(column) 个码字校验子不为零")
        }
    }

    // MARK: - Payload 位置映射

    func testPayloadLayoutCoversLDCGridWithoutCollisions() {
        XCTAssertEqual(BluRayPayloadLayout.channelOffsets.count, 65_536)
        XCTAssertEqual(BluRayPayloadLayout.physicalOrder.count, 65_536)
        // 位置按通道位偏移升序排列。
        let order = BluRayPayloadLayout.physicalOrder
        XCTAssertEqual(order.first, order.min(by: { BluRayPayloadLayout.channelOffsets[$0] < BluRayPayloadLayout.channelOffsets[$1] }))

        var seen = Set<Int>()
        for sector in 0..<32 {
            for offset in 0..<2048 {
                let s = UInt32(sector)
                let frame = BluRayPayloadLayout.recordingFrame(sector: s, byteOffset: offset)
                let ldc = BluRayPayloadLayout.ldcColumn(sector: s, byteOffset: offset)
                let ecc = BluRayPayloadLayout.eccColumn(sector: s, byteOffset: offset)
                XCTAssertTrue((0..<496).contains(frame))
                XCTAssertTrue((0..<152).contains(ldc))
                XCTAssertTrue((0..<155).contains(ecc))
                let key = frame * 152 + ldc
                XCTAssertTrue(seen.insert(key).inserted, "位置重复：sector \(sector) offset \(offset)")
            }
        }
        XCTAssertEqual(seen.count, 65_536)
        // 覆盖 304×216 网格里的 65,536 个位置，剩 128 个 EDC 位置。
        XCTAssertEqual(304 * 216 - seen.count, 128)
    }

    func testPayloadPositionMatchesChannelOffsetTable() throws {
        let geometry = try BluRayTrackGeometry(innerRadiusMm: 24, outerRadiusMm: 58, totalSectors: 640)
        let position = try BluRayPayloadLayout.position(sector: 33, byteOffset: 100, geometry: geometry)
        XCTAssertEqual(position.physicalSectorNumber, BluRaySpec.firstLayer0PhysicalSector + 33)
        XCTAssertEqual(position.recordingFrame, BluRayPayloadLayout.recordingFrame(sector: 33, byteOffset: 100))
        let expected = Double(BluRaySpec.channelBitsPerRecordingUnit) * 1
            + BluRayPayloadLayout.channelOffset(sector: 33, byteOffset: 100)
        XCTAssertEqual(position.nominalChannelBitPosition, expected, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(position.radiusMm, 24)
        XCTAssertLessThanOrEqual(position.radiusMm, 58)
    }

    // MARK: - 轨迹几何

    func testTrackGeometryEndpointsAndPitch() throws {
        let geometry = try BluRayTrackGeometry(innerRadiusMm: 24, outerRadiusMm: 58, totalSectors: 12_219_392)
        let start = try geometry.trackPoint(sectorPosition: 0)
        let end = try geometry.trackPoint(sectorPosition: 12_219_392)
        XCTAssertEqual(start.radiusMm, 24, accuracy: 1e-9)
        XCTAssertEqual(end.radiusMm, 58, accuracy: 1e-9)
        // 名义轨距 0.320 µm：反算值应贴近，允许 1% 偏差（薄螺旋近似）。
        XCTAssertEqual(geometry.effectiveTrackPitchMicrometres, 0.320, accuracy: 0.0032)
        // 总轨长：381,856 簇 × 962,136 通道位 × 74.5 nm。
        let expectedLength = 12_219_392.0 / 32 * 962_136 * 74.5e-6
        XCTAssertEqual(geometry.trackLengthPerLayerMm, expectedLength, accuracy: 1e-6)
    }

    // MARK: - 3T / 6T 完整簇统计（源项目文档记录值）

    func testFullClusterThreeTRunCountMatchesSourceDocumentation() throws {
        // 源项目 docs/BLURAY_BYTE_DENSITY.md：基准 PSN 0x100000 上，
        // 整簇 958,272 通道位、扰码域 Q = 0xAA 时有 265,136 个 3T。
        let count = try clusterGapCount(qByte: 0xAA, gap: 3)
        XCTAssertEqual(count, 265_136, "0xAA 整簇 3T 次数与源项目文档不一致")
    }

    func testFullClusterSixTRunCountMatchesSourceDocumentation() throws {
        // 同文档：Q = 0x44 时有 116,575 个 6T。
        let count = try clusterGapCount(qByte: 0x44, gap: 6)
        XCTAssertEqual(count, 116_575, "0x44 整簇 6T 次数与源项目文档不一致")
    }

    /// 构造扰码域 Q 恒为 `qByte` 的用户数据，跑完整 RUB 后统计数据侧间隔。
    ///
    /// 必须走完整 `BluRayRecordingUnit`：帧的 DC 控制位选择依赖 run-in 结束时的
    /// 电平与 DSV，从零电平起算会得到不同的调制序列（源项目文档的统计值就是
    /// 在 run-in 上下文里得到的）。
    private func clusterGapCount(qByte: UInt8, gap: Int) throws -> Int {
        let psn = BluRaySpec.firstLayer0PhysicalSector
        let mask = BluRayScrambler.mask(physicalSectorNumber: psn)
        var userData = [UInt8](repeating: 0, count: BluRaySpec.payloadBytesPerCluster)
        for sector in 0..<32 {
            for index in 0..<2048 {
                // host = Q XOR 掩码；ECC 编码时再加扰后恢复 Q。
                userData[sector * 2048 + index] = qByte ^ mask[index]
            }
        }
        let rub = try BluRayRecordingUnit.encode(
            userData: userData,
            firstPhysicalSectorNumber: psn
        )
        let data = BluRayRecordingUnit.dataModulationBits(of: rub)
        XCTAssertEqual(data.count, 958_272)
        return BluRayRunStatistics.countGaps(ofLength: gap, in: data)
    }

    // MARK: - 辅助

    /// RLL(1,7)：相邻 1 之间至少 1 个、至多 7 个 0。
    private func assertRLL17(_ bits: [UInt8], context: String, file: StaticString = #filePath, line: UInt = #line) {
        var previous: Int?
        var leadingZeros = 0
        for (index, bit) in bits.enumerated() where bit == 1 {
            if let last = previous {
                let zeros = index - last - 1
                XCTAssertGreaterThanOrEqual(zeros, 1, "\(context)：\(last) 与 \(index) 之间 0 少于 1 个", file: file, line: line)
                XCTAssertLessThanOrEqual(zeros, 7, "\(context)：\(last) 与 \(index) 之间 0 多于 7 个", file: file, line: line)
            } else {
                leadingZeros = index
            }
            previous = index
        }
        XCTAssertLessThanOrEqual(leadingZeros, 7, "\(context)：起始 0 过长", file: file, line: line)
    }
}

/// 可复现的伪随机数（SplitMix64），避免测试依赖系统随机源。
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
