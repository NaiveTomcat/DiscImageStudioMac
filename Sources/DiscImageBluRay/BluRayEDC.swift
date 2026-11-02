import Foundation
import DiscImageCore

/// BD-R data frame 的 4 字节 EDC（ISO/IEC 30190:2021 §13.2–13.3）。
///
/// 多项式 0x80000011、MSB-first、初值 0、无最终取反。把 4 字节 EDC 按大端追加到
/// 2048 字节 payload 之后，整个 2052 字节的余数为 0 —— 这是单元测试的核心断言。
public enum BluRayEDC {
    public static let userDataBytes = BluRaySpec.bytesPerSector
    public static let dataFrameBytes = BluRaySpec.dataFrameBytes
    public static let parityBytes = 4

    private static let polynomial: UInt32 = 0x8000_0011
    private static let table: [UInt32] = buildTable()

    /// 计算 2048 字节 payload 的 EDC（4 字节大端值）。
    public static func compute(_ data: [UInt8]) -> UInt32 {
        var remainder: UInt32 = 0
        for value in data {
            let index = Int((remainder >> 24) ^ UInt32(value))
            remainder = (remainder << 8) ^ table[index]
        }
        return remainder
    }

    /// 计算任意长度字节串的多项式余数（测试用：整帧余数应为 0）。
    public static func remainder(_ data: [UInt8]) -> UInt32 {
        compute(data)
    }

    /// 组装 2052 字节 data frame：payload + 大端 EDC。
    public static func writeDataFrame(userData: [UInt8], into destination: inout [UInt8]) throws {
        guard userData.count == userDataBytes else {
            throw DiscError.encoding("BD data frame 的 payload 必须是 2048 字节（当前 \(userData.count)）")
        }
        guard destination.count == dataFrameBytes else {
            throw DiscError.encoding("BD data frame 必须是 2052 字节（当前 \(destination.count)）")
        }
        let edc = compute(userData)
        destination.replaceSubrange(0..<userDataBytes, with: userData)
        destination[userDataBytes] = UInt8((edc >> 24) & 0xFF)
        destination[userDataBytes + 1] = UInt8((edc >> 16) & 0xFF)
        destination[userDataBytes + 2] = UInt8((edc >> 8) & 0xFF)
        destination[userDataBytes + 3] = UInt8(edc & 0xFF)
    }

    /// 生成一个完整 data frame。
    public static func dataFrame(userData: [UInt8]) throws -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: dataFrameBytes)
        try writeDataFrame(userData: userData, into: &frame)
        return frame
    }

    static func buildTable() -> [UInt32] {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index) << 24
            for _ in 0..<8 {
                value = (value << 1) ^ ((value & 0x8000_0000) != 0 ? polynomial : 0)
            }
            table[index] = value
        }
        return table
    }
}
