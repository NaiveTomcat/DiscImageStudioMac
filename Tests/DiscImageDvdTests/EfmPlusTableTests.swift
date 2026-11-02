import DiscImageCore
import XCTest

@testable import DiscImageDvd

/// EFMPlus 表来自源项目 `EfmPlusTables.Generated.cs` 的机械转换，这里锁定几个
/// 与源项目 `SelfTests.TestTables` 相同的抽查点，防止转换脚本跑偏。
final class EfmPlusTableTests: XCTestCase {
    func testTableSizes() {
        XCTAssertEqual(EfmPlusTables.mainWords.count, 256 * 4)
        XCTAssertEqual(EfmPlusTables.mainNextStates.count, 256 * 4)
        XCTAssertEqual(EfmPlusTables.substitutionWords.count, 88 * 4)
        XCTAssertEqual(EfmPlusTables.substitutionNextStates.count, 88 * 4)
    }

    func testSpotValuesMatchSourceSelfTests() throws {
        let mainZeroStateOne = try EfmPlusTables.mainWord(0, state: 1)
        XCTAssertEqual(mainZeroStateOne.word, 0x2009)
        XCTAssertEqual(mainZeroStateOne.nextState, 1)
        XCTAssertEqual(try EfmPlusTables.mainWord(0, state: 2).word, 0x4120)
        XCTAssertEqual(try EfmPlusTables.mainWord(255, state: 4).word, 0x4212)
        XCTAssertEqual(try EfmPlusTables.substitutionWord(0, state: 1).word, 0x0480)
    }

    func testAllNextStatesAreValid() {
        for nextState in EfmPlusTables.mainNextStates {
            XCTAssertTrue((1...4).contains(Int(nextState)))
        }
        for nextState in EfmPlusTables.substitutionNextStates {
            XCTAssertTrue((1...4).contains(Int(nextState)))
        }
    }

    func testSyncCodesEndInTransition() throws {
        for state in 1...4 {
            for category in 0...7 {
                for primary in [true, false] {
                    let code = try EfmPlusTables.syncCode(state: state, category: category, primary: primary)
                    // 所有 SYNC 码都以 ...0001 结尾：最后一位必然是 transition（下一状态恒为 1）。
                    XCTAssertEqual(code & 1, 1, "state \(state) category \(category) primary \(primary)")
                }
            }
        }
        XCTAssertEqual(try EfmPlusTables.syncCode(state: 1, category: 0, primary: true), 0x1244_0011)
        XCTAssertEqual(try EfmPlusTables.syncCode(state: 2, category: 7, primary: false), 0x2404_0011)
        XCTAssertEqual(try EfmPlusTables.syncCode(state: 3, category: 0, primary: true), 0x9204_0011)
        XCTAssertEqual(try EfmPlusTables.syncCode(state: 4, category: 0, primary: false), 0x9244_0011)
    }

    func testWordZeroRunBounds() {
        // 主表/替换表里的每个码字，其首尾零游程都不能超过 RLL(2,10) 的 10。
        for word in EfmPlusTables.mainWords + EfmPlusTables.substitutionWords {
            var leading = 0
            var bit = 15
            while bit >= 0 && ((word >> UInt16(bit)) & 1) == 0 {
                leading += 1
                bit -= 1
            }
            var trailing = 0
            bit = 0
            while bit < 16 && ((word >> UInt16(bit)) & 1) == 0 {
                trailing += 1
                bit += 1
            }
            XCTAssertLessThanOrEqual(leading, 10, String(format: "0x%04X", word))
            XCTAssertLessThanOrEqual(trailing, 10, String(format: "0x%04X", word))
        }
    }
}
