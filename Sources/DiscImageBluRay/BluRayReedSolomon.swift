import Foundation
import DiscImageCore

/// BD-R 的缩短 RS 码：GF(256)、本原多项式 0x11D、根从 α⁰ 开始。
///
/// - 地址字段：RS(9,5) —— 5 个信息字节 + 4 个校验字节
/// - LDC / BIS：RS(n, n−32) —— 统一 32 个校验字节
///
/// 与 `BluRayEccEncoder.cs` 的做法一致：生成多项式按升幂存系数，系统码校验位
/// 直接由多项式长除法余数得到。可用 `syndromes` 独立复核（全零即合法码字）。
public enum BluRayReedSolomon {
    static let exponentTable: [UInt8] = buildExponents()
    static let logarithmTable: [UInt8] = buildLogarithms()
    static let generator4: [UInt8] = buildGenerator(degree: 4)
    static let generator32: [UInt8] = buildGenerator(degree: 32)

    /// 计算校验位。`parityLength` 只允许 4（地址）或 32（LDC/BIS）。
    public static func parity(information: [UInt8], parityLength: Int) throws -> [UInt8] {
        guard parityLength == 4 || parityLength == 32 else {
            throw DiscError.encoding("BD RS 校验位长度只能是 4 或 32（当前 \(parityLength)）")
        }
        guard !information.isEmpty, information.count + parityLength <= 255 else {
            throw DiscError.encoding("BD RS 码字必须落在 1…255 个符号内（当前 \(information.count) + \(parityLength)）")
        }
        let generator = parityLength == 4 ? generator4 : generator32
        var work = [UInt8](repeating: 0, count: information.count + parityLength)
        work.replaceSubrange(0..<information.count, with: information)
        for index in 0..<information.count {
            let leading = work[index]
            if leading == 0 { continue }
            for coefficient in 1..<generator.count {
                work[index + coefficient] ^= multiply(leading, generator[coefficient])
            }
        }
        return Array(work[information.count..<(information.count + parityLength)])
    }

    /// 就地追加校验位。
    public static func appendParity(to codeword: inout [UInt8], parityLength: Int) throws {
        let information = codeword
        let parity = try parity(information: information, parityLength: parityLength)
        codeword.append(contentsOf: parity)
    }

    /// 计算码字在 α⁰…α^(parityLength−1) 处的校验子。
    ///
    /// 合法码字（信息字节在前、校验字节在后）的全部校验子都应为零。
    public static func syndromes(_ codeword: [UInt8], parityLength: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: parityLength)
        let count = codeword.count
        guard count > 0 else { return result }
        for root in 0..<parityLength {
            var sum: UInt8 = 0
            for index in 0..<count {
                let symbol = codeword[index]
                if symbol == 0 { continue }
                let exponent = (root * (count - 1 - index)) % 255
                sum ^= multiply(symbol, exponentTable[exponent])
            }
            result[root] = sum
        }
        return result
    }

    /// 校验子是否全零。
    public static func isCodeword(_ codeword: [UInt8], parityLength: Int) -> Bool {
        !syndromes(codeword, parityLength: parityLength).contains { $0 != 0 }
    }

    /// GF(256) 乘法（对数表实现；指数表长 510 足以覆盖两次对数和）。
    static func multiply(_ left: UInt8, _ right: UInt8) -> UInt8 {
        if left == 0 || right == 0 { return 0 }
        return exponentTable[Int(logarithmTable[Int(left)]) + Int(logarithmTable[Int(right)])]
    }

    /// 生成多项式 g(x) = Π(x + α^root)，系数按升幂存放（g[0] 为常数项）。
    static func buildGenerator(degree: Int) -> [UInt8] {
        var result: [UInt8] = [1]
        for root in 0..<degree {
            var next = [UInt8](repeating: 0, count: result.count + 1)
            for index in 0..<result.count {
                next[index] ^= result[index]
                next[index + 1] ^= multiply(result[index], exponentTable[root])
            }
            result = next
        }
        return result
    }

    static func buildExponents() -> [UInt8] {
        var table = [UInt8](repeating: 0, count: 510)
        var value = 1
        for index in 0..<255 {
            table[index] = UInt8(value)
            value <<= 1
            if value & 0x100 != 0 { value ^= 0x11D }
        }
        for index in 255..<table.count {
            table[index] = table[index - 255]
        }
        return table
    }

    static func buildLogarithms() -> [UInt8] {
        var table = [UInt8](repeating: 0, count: 256)
        for index in 0..<255 {
            table[Int(exponentTable[index])] = UInt8(index)
        }
        return table
    }
}
