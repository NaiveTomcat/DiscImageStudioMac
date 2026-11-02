import Foundation
import DiscImageCore

/// 17PP 变长 RLL(1,7) 调制（ISO/IEC 30190:2021 §13.17.2，Figure 41）。
///
/// 输入是「每个字节一个 0/1 位」的数组（MSB-first），长度必须是偶数：
/// 17PP 每次吃掉 1、2、3 或 4 个数据位对（即 2/4/6/8 个数据位），
/// 输出 3/6/9/12 个通道位，平均码率 2:3。
///
/// Figure 41 的特殊替换规则（`11 01 11` 前缀）用于打断过长重复，
/// 替换后仍保证 RLL(1,7)，代价是 6 个数据位 → 9 个通道位。
public enum BluRay17PP {
    public struct Result: Sendable, Equatable {
        public let modulationBits: [UInt8]
        public let usedTermination: Bool
        public var lastModulationBit: UInt8 { modulationBits.last ?? 0 }
    }

    /// 编码偶数个数据位。`previousModulationBit` 是前一个通道位，供 `11` 对消歧。
    public static func encode(dataBits: [UInt8], previousModulationBit: UInt8 = 0) throws -> Result {
        guard dataBits.count % 2 == 0 else {
            throw DiscError.encoding("17PP 只接受偶数个数据位（当前 \(dataBits.count)）")
        }
        guard previousModulationBit <= 1 else {
            throw DiscError.encoding("previousModulationBit 只能是 0 或 1")
        }
        for bit in dataBits where bit > 1 {
            throw DiscError.encoding("数据位必须表示为 0 或 1")
        }

        var output = [UInt8](repeating: 0, count: dataBits.count / 2 * 3)
        var source = 0
        var cursor = 0
        var previous = previousModulationBit
        var terminated = false
        while source < dataBits.count {
            let word = nextWord(dataBits, from: source, previous: previous)
            let channelLength = word.dataLength / 2 * 3
            var bit = channelLength - 1
            while bit >= 0 {
                output[cursor] = UInt8((word.channelValue >> bit) & 1)
                cursor += 1
                bit -= 1
            }
            previous = output[cursor - 1]
            source += word.dataLength
            terminated = word.isTerminating
        }
        guard cursor == output.count else {
            throw DiscError.encoding("17PP 输出长度异常（\(cursor) ≠ \(output.count)）")
        }
        return Result(modulationBits: output, usedTermination: terminated)
    }

    /// NRZI：调制位 1 翻转电平，0 保持。
    public static func channelLevels(modulationBits: [UInt8], initialLevel: UInt8 = 0) throws -> [UInt8] {
        guard initialLevel <= 1 else {
            throw DiscError.encoding("initialLevel 只能是 0 或 1")
        }
        var levels = [UInt8](repeating: 0, count: modulationBits.count)
        var level = initialLevel
        for index in 0..<modulationBits.count {
            let transition = modulationBits[index]
            guard transition <= 1 else {
                throw DiscError.encoding("调制位必须表示为 0 或 1")
            }
            level ^= transition
            levels[index] = level
        }
        return levels
    }

    struct Codeword {
        let dataLength: Int
        let channelValue: Int
        let isTerminating: Bool
    }

    /// 应用 Figure 41 替换规则后，当前位置的下一个码字。
    ///
    /// 替换条件：剩余 ≥ 8 位、以 `110111` 开头，且紧随其后的码字以 `010` 起始。
    /// 前缀码意味着「从某个码字边界继续编码」与「从头重编码」结果逐位一致，
    /// 贪心 DC 控制正是靠这一点做增量编码。
    static func nextWord(_ dataBits: [UInt8], from source: Int, previous: UInt8) -> Codeword {
        if dataBits.count - source >= 8,
           readBits(dataBits, from: source, count: 6) == 0b110111,
           beginsWith010(convertNext(dataBits, from: source + 6, previous: 1)) {
            return Codeword(dataLength: 6, channelValue: 0b001_000_000, isTerminating: false)
        }
        return convertNext(dataBits, from: source, previous: previous)
    }

    /// 依据当前数据位对（最多看 8 位）决定码字。
    static func convertNext(_ bits: [UInt8], from start: Int, previous: UInt8) -> Codeword {
        let remaining = bits.count - start
        let firstPair = readBits(bits, from: start, count: 2)
        switch firstPair {
        case 1: return Codeword(dataLength: 2, channelValue: 0b010, isTerminating: false)
        case 2: return Codeword(dataLength: 2, channelValue: 0b001, isTerminating: false)
        case 3:
            return Codeword(dataLength: 2, channelValue: previous == 1 ? 0b000 : 0b101, isTerminating: false)
        default:
            break
        }
        // firstPair == 0
        if remaining == 2 {
            return Codeword(dataLength: 2, channelValue: 0b000, isTerminating: true)
        }
        let nextPair = readBits(bits, from: start + 2, count: 2)
        switch nextPair {
        case 1: return Codeword(dataLength: 4, channelValue: 0b000100, isTerminating: false)
        case 2: return Codeword(dataLength: 4, channelValue: 0b010000, isTerminating: false)
        case 3: return Codeword(dataLength: 4, channelValue: 0b010100, isTerminating: false)
        default: break
        }
        if remaining == 4 {
            return Codeword(dataLength: 4, channelValue: 0b010100, isTerminating: true)
        }
        let thirdPair = readBits(bits, from: start + 4, count: 2)
        if remaining >= 8, readBits(bits, from: start + 6, count: 2) == 0 {
            if thirdPair == 0 {
                return Codeword(dataLength: 8, channelValue: 0b010100_100100, isTerminating: false)
            }
            if thirdPair == 2 {
                return Codeword(dataLength: 8, channelValue: 0b000100_100100, isTerminating: false)
            }
        }
        switch thirdPair {
        case 0: return Codeword(dataLength: 6, channelValue: 0b010100_000, isTerminating: false)
        case 1: return Codeword(dataLength: 6, channelValue: 0b010100_100, isTerminating: false)
        case 2: return Codeword(dataLength: 6, channelValue: 0b000100_000, isTerminating: false)
        default: return Codeword(dataLength: 6, channelValue: 0b000100_100, isTerminating: false)
        }
    }

    static func beginsWith010(_ word: Codeword) -> Bool {
        let channelLength = word.dataLength / 2 * 3
        return (word.channelValue >> (channelLength - 3)) == 0b010
    }

    static func readBits(_ bits: [UInt8], from start: Int, count: Int) -> Int {
        var value = 0
        for offset in 0..<count {
            value = (value << 1) | Int(bits[start + offset])
        }
        return value
    }
}
