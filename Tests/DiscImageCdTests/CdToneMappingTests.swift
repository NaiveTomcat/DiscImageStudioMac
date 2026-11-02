import DiscImageCore
import Foundation
import XCTest

@testable import DiscImageCd

/// 灰阶与影调：2 阶 `0x0D`/`0xAA`、4 阶 `0x0D`/`0x10`/`0x63`/`0xAA`，
/// 判定一律走 `DiscImageCore.ToneProfile`（task-2 第 2 条）。
final class CdToneMappingTests: XCTestCase {

    func testPalettes() {
        XCTAssertEqual(CdToneMapping.twoLevelPalette, [0x0D, 0xAA])
        XCTAssertEqual(CdToneMapping.fourLevelPalette, [0x0D, 0x10, 0x63, 0xAA])
        XCTAssertEqual(CdToneMapping.palette(levels: 2), [0x0D, 0xAA])
        XCTAssertEqual(CdToneMapping.palette(levels: 4), [0x0D, 0x10, 0x63, 0xAA])
        // 非法阶数退化为 2 阶，与 ToneProfile 的语义一致。
        XCTAssertEqual(CdToneMapping.palette(levels: 7), [0x0D, 0xAA])
    }

    func testLegacyBinaryMappingIsTheHistoricThreshold() {
        let tone = ToneProfile.legacyBinary
        XCTAssertTrue(tone.isLegacyBinary)
        var expected = [UInt8](repeating: 0x0D, count: 128)
        expected.append(contentsOf: [UInt8](repeating: 0xAA, count: 128))
        for gray in 0...255 {
            XCTAssertEqual(
                CdToneMapping.map(gray: UInt8(gray), tone: tone, sampleIndex: Int64(gray)),
                expected[gray],
                "灰度 \(gray)"
            )
        }
    }

    func testFourLevelLegacyBins() {
        // 无抖动时按 64 等宽分箱（ToneProfile.levelIndex 的 gray >> 6）。
        let tone = ToneProfile(ditherStrength: 0, levels: 4, brightness: 0)
        let expectations: [(UInt8, UInt8)] = [
            (0, 0x0D), (63, 0x0D),
            (64, 0x10), (127, 0x10),
            (128, 0x63), (191, 0x63),
            (192, 0xAA), (255, 0xAA),
        ]
        for (gray, paletteByte) in expectations {
            XCTAssertEqual(
                CdToneMapping.map(gray: gray, tone: tone, sampleIndex: Int64(gray)),
                paletteByte,
                "灰度 \(gray)"
            )
        }
    }

    func testDitherKeepsPaletteMembership() {
        let twoLevel = ToneProfile(ditherStrength: 1, levels: 2, brightness: 0)
        let fourLevel = ToneProfile(ditherStrength: 1, levels: 4, brightness: 0)
        for gray in stride(from: 0, through: 255, by: 17) {
            for index in 0..<32 {
                let two = CdToneMapping.map(gray: UInt8(gray), tone: twoLevel, sampleIndex: Int64(index))
                let four = CdToneMapping.map(gray: UInt8(gray), tone: fourLevel, sampleIndex: Int64(index))
                XCTAssertTrue(CdToneMapping.isPaletteByte(two, levels: 2), "2 阶输出 \(two)")
                XCTAssertTrue(CdToneMapping.isPaletteByte(four, levels: 4), "4 阶输出 \(four)")
            }
        }
    }

    func testDitherDependsOnLogicalSampleIndex() {
        let tone = ToneProfile(ditherStrength: 1, levels: 2, brightness: 0)
        var seen = Set<UInt8>()
        for index in 0..<256 {
            seen.insert(CdToneMapping.map(gray: 128, tone: tone, sampleIndex: Int64(index)))
        }
        // 中灰在 100% 抖动下两种档位都会出现（否则样本索引根本没起作用）。
        XCTAssertEqual(seen, [0x0D, 0xAA])
    }

    func testFourLevelDitherUsesAllFourLevels() {
        let tone = ToneProfile(ditherStrength: 1, levels: 4, brightness: 0)
        var seen = Set<UInt8>()
        for gray in stride(from: 0, through: 255, by: 5) {
            for index in 0..<16 {
                seen.insert(CdToneMapping.map(gray: UInt8(gray), tone: tone, sampleIndex: Int64(index)))
            }
        }
        XCTAssertEqual(seen, Set(CdToneMapping.fourLevelPalette))
    }

    func testMappingIsDeterministicPerSampleIndex() {
        let tone = ToneProfile(ditherStrength: 0.75, levels: 4, brightness: 12, srgbLinearization: 0.5)
        for index in [Int64(0), 1, 97, 12_345, 846_364_847] {
            let first = CdToneMapping.map(gray: 137, tone: tone, sampleIndex: index)
            let second = CdToneMapping.map(gray: 137, tone: tone, sampleIndex: index)
            XCTAssertEqual(first, second)
        }
    }

    func testDisplayGrayRoundTrip() {
        XCTAssertEqual(CdToneMapping.displayGray(paletteByte: 0x0D), 0)
        XCTAssertEqual(CdToneMapping.displayGray(paletteByte: 0x10), 85)
        XCTAssertEqual(CdToneMapping.displayGray(paletteByte: 0x21), 96)
        XCTAssertEqual(CdToneMapping.displayGray(paletteByte: 0x28), 160)
        XCTAssertEqual(CdToneMapping.displayGray(paletteByte: 0x63), 170)
        XCTAssertEqual(CdToneMapping.displayGray(paletteByte: 0xAA), 255)
        XCTAssertEqual(CdToneMapping.displayGray(paletteByte: 0x33), 0x33)
    }

    func testBrightnessShiftsThreshold() {
        let dark = ToneProfile(ditherStrength: 0, levels: 2, brightness: -40)
        let bright = ToneProfile(ditherStrength: 0, levels: 2, brightness: 40)
        // 同样的灰度，变亮之后更容易判成白。
        XCTAssertEqual(CdToneMapping.map(gray: 160, tone: dark, sampleIndex: 0), 0x0D)
        XCTAssertEqual(CdToneMapping.map(gray: 160, tone: bright, sampleIndex: 0), 0xAA)
    }
}
