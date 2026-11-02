import XCTest
@testable import DiscImageCore

final class ToneProfileTests: XCTestCase {

    func testLegacyBinaryKeepsHistoricalThreshold() {
        let tone = ToneProfile.legacyBinary
        XCTAssertTrue(tone.isLegacyBinary)
        XCTAssertFalse(tone.useWhite(127, sampleIndex: 0))
        XCTAssertTrue(tone.useWhite(128, sampleIndex: 0))
        XCTAssertTrue(tone.useWhite(255, sampleIndex: 12_345))
        XCTAssertFalse(tone.useWhite(0, sampleIndex: 999))
    }

    func testDitherPhaseIsDeterministicAndInRange() {
        for index in [Int64(0), 1, 2, 77, 1_000_003, 9_876_543_210] {
            let phase = ToneDither.phase(index)
            XCTAssertGreaterThanOrEqual(phase, 0)
            XCTAssertLessThan(phase, 1)
            XCTAssertEqual(phase, ToneDither.phase(index), "同一索引必须给出同一相位")
        }
    }

    func testDitherPhaseIsDecorrelated() {
        // 相邻索引、跨步索引都不应同相（否则预览会拍出环状条纹）
        var distinct = Set<Int>()
        for index in 0..<256 {
            distinct.insert(Int(ToneDither.phase(Int64(index)) * 1000))
        }
        XCTAssertGreaterThan(distinct.count, 200)
    }

    func testDitherMakesMidGreyProbabilistic() {
        let tone = ToneProfile(ditherStrength: 1.0, levels: 2, brightness: 0)
        var white = 0
        let samples = 2_000
        for index in 0..<samples {
            if tone.useWhite(128, sampleIndex: Int64(index)) { white += 1 }
        }
        // 中灰在 100% 抖动下应该接近一半白、一半黑
        let ratio = Double(white) / Double(samples)
        XCTAssertGreaterThan(ratio, 0.35)
        XCTAssertLessThan(ratio, 0.65)
    }

    func testBrightnessShiftsRamp() {
        let darker = ToneProfile(ditherStrength: 0, levels: 2, brightness: -64)
        XCTAssertLessThan(darker.adjustedGray(128), 128)
        let brighter = ToneProfile(ditherStrength: 0, levels: 2, brightness: 64)
        XCTAssertGreaterThan(brighter.adjustedGray(128), 128)
        // 极值夹紧，不会回绕
        XCTAssertEqual(darker.adjustedGray(0), 0)
        XCTAssertEqual(brighter.adjustedGray(255), 255)
    }

    func testSrgbLinearizationDarkensMidtones() {
        let linear = ToneProfile(ditherStrength: 0, levels: 2, brightness: 0, srgbLinearization: 1)
        XCTAssertLessThan(linear.adjustedGray(128), 128)
        XCTAssertEqual(linear.adjustedGray(0), 0)
        XCTAssertEqual(linear.adjustedGray(255), 255)
        // 0 表示完全关闭，和默认一致
        let disabled = ToneProfile(ditherStrength: 0, levels: 2, brightness: 0, srgbLinearization: 0)
        XCTAssertEqual(disabled.adjustedGray(200), 200)
    }

    func testFourLevelBucketsMatchSource() {
        let tone = ToneProfile(ditherStrength: 0, levels: 4, brightness: 0)
        XCTAssertEqual(tone.levelIndex(0, sampleIndex: 0), 0)
        XCTAssertEqual(tone.levelIndex(63, sampleIndex: 0), 0)
        XCTAssertEqual(tone.levelIndex(64, sampleIndex: 0), 1)
        XCTAssertEqual(tone.levelIndex(128, sampleIndex: 0), 2)
        XCTAssertEqual(tone.levelIndex(192, sampleIndex: 0), 3)
        XCTAssertEqual(tone.levelIndex(255, sampleIndex: 0), 3)
    }

    func testFourLevelDitherStaysInRange() {
        let tone = ToneProfile(ditherStrength: 1.0, levels: 4, brightness: 0)
        for index in 0..<500 {
            let level = tone.levelIndex(128, sampleIndex: Int64(index))
            XCTAssertTrue((0...3).contains(level))
        }
    }

    func testValidationBoundaries() {
        XCTAssertThrowsError(try ToneProfile(ditherStrength: 1.5).validate())
        XCTAssertThrowsError(try ToneProfile(levels: 3).validate())
        XCTAssertThrowsError(try ToneProfile(brightness: 65).validate())
        XCTAssertThrowsError(try ToneProfile(srgbLinearization: 2).validate())
        XCTAssertNoThrow(try ToneProfile.default.validate())
    }

    func testNormalizedClampsInsteadOfThrowing() {
        let wild = ToneProfile(ditherStrength: 3, levels: 7, brightness: 900, srgbLinearization: -2)
        let normalized = wild.normalized()
        XCTAssertEqual(normalized.ditherStrength, 1)
        XCTAssertEqual(normalized.levels, 2)
        XCTAssertEqual(normalized.brightness, 64)
        XCTAssertEqual(normalized.srgbLinearization, 0)
    }

    func testToneProfileCodableDefaults() throws {
        let decoded = try JSONDecoder().decode(ToneProfile.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.ditherStrength, 0.75)
        XCTAssertEqual(decoded.levels, 2)
        XCTAssertEqual(decoded.brightness, 0)
    }
}
