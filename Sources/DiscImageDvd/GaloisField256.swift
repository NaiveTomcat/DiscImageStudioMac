import DiscImageCore
import Foundation

/// GF(2^8)，本原多项式 `x^8 + x^4 + x^3 + x^2 + 1`（0x11D）。
///
/// 与源项目 `GaloisField256` 完全同构：指数表 512 项、对数表 256 项，
/// 乘法走「查表 + 指数相加」。DVD 的 PI/PO/IED 都是这个域上的 RS 码。
enum GaloisField256 {
    private static let tables: (exp: [UInt8], log: [UInt8]) = {
        var exp = [UInt8](repeating: 0, count: 512)
        var log = [UInt8](repeating: 0, count: 256)
        var value = 1
        for exponent in 0..<255 {
            exp[exponent] = UInt8(value)
            log[value] = UInt8(exponent)
            value <<= 1
            if value & 0x100 != 0 {
                value ^= 0x11D
            }
        }
        for exponent in 255..<512 {
            exp[exponent] = exp[exponent - 255]
        }
        return (exp, log)
    }()

    static func multiply(_ left: UInt8, _ right: UInt8) -> UInt8 {
        if left == 0 || right == 0 { return 0 }
        let exponent = Int(tables.log[Int(left)]) + Int(tables.log[Int(right)])
        return tables.exp[exponent]
    }

    static func alphaPower(_ exponent: Int) -> UInt8 {
        tables.exp[((exponent % 255) + 255) % 255]
    }
}
