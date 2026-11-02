import DiscImageCore
import Foundation

/// DVD 使用的三个 Reed-Solomon 码（GF(2^8)，生成多项式根为 α^0, α^1, …）。
///
/// - PI：RS(182,172)，10 个校验字节，208 行逐行
/// - PO：RS(208,192)，16 个校验字节，172 列逐列
/// - IED：RS(6,4)，2 个校验字节，盖在 Data Frame 的 ID 上
///
/// 实现与源项目 `ReedSolomon.cs` 逐行对应：用「移位寄存器 + 反馈」求校验，
/// `hasZeroRemainder` 把整个码字再喂一遍，余式全零即合法。
enum ReedSolomon {
    static let piGenerator = buildGenerator(parityBytes: 10)
    static let poGenerator = buildGenerator(parityBytes: 16)
    static let iedGenerator = buildGenerator(parityBytes: 2)

    /// 追加 PI 校验字节（10 个）。
    static func piParity(_ data: ArraySlice<UInt8>) -> [UInt8] {
        encode(data, generator: piGenerator)
    }

    /// 追加 PO 校验字节（16 个）。
    static func poParity(_ data: ArraySlice<UInt8>) -> [UInt8] {
        encode(data, generator: poGenerator)
    }

    /// 追加 IED 校验字节（2 个）。
    static func iedParity(_ data: ArraySlice<UInt8>) -> [UInt8] {
        encode(data, generator: iedGenerator)
    }

    /// 码字余式是否全零。`parityBytes` 决定用哪个生成多项式。
    static func hasZeroRemainder(_ codeword: ArraySlice<UInt8>, parityBytes: Int) -> Bool {
        let generator = generator(for: parityBytes)
        let remainder = encode(codeword, generator: generator)
        return remainder.allSatisfy { $0 == 0 }
    }

    static func generator(for parityBytes: Int) -> [UInt8] {
        switch parityBytes {
        case 2: return iedGenerator
        case 10: return piGenerator
        case 16: return poGenerator
        default: return buildGenerator(parityBytes: parityBytes)
        }
    }

    /// 返回 `data` 的 RS 校验字节。`generator` 的首项恒为 1。
    static func encode(_ data: ArraySlice<UInt8>, generator: [UInt8]) -> [UInt8] {
        let parityCount = generator.count - 1
        guard parityCount > 0 else { return [] }
        var parity = [UInt8](repeating: 0, count: parityCount)
        for value in data {
            let feedback = value ^ parity[0]
            var index = 0
            while index < parityCount - 1 {
                parity[index] = parity[index + 1] ^ GaloisField256.multiply(feedback, generator[index + 1])
                index += 1
            }
            parity[parityCount - 1] = GaloisField256.multiply(feedback, generator[parityCount])
        }
        return parity
    }

    private static func buildGenerator(parityBytes: Int) -> [UInt8] {
        var polynomial: [UInt8] = [1]
        for root in 0..<parityBytes {
            var next = [UInt8](repeating: 0, count: polynomial.count + 1)
            let alpha = GaloisField256.alphaPower(root)
            for index in 0..<polynomial.count {
                next[index] ^= polynomial[index]
                next[index + 1] ^= GaloisField256.multiply(polynomial[index], alpha)
            }
            polynomial = next
        }
        return polynomial
    }
}
