import Foundation
import DiscImageCore

/// Recording frame 组装：同步帧 + 28 个 DC 控制位 + 17PP + NRZI。
///
/// 每帧 155 个 ECC 字节 = 1240 个数据位；前 25 位之后每 45 位插一个 DC 控制位，
/// 合计 28 个。加 30 位同步帧后调制为 1932 通道位。
///
/// 注意：本类型只接受**调用方给定**的 DC 控制位；策略在
/// `BluRayGreedyDCControl` 里。全 0 的 DC 控制位只适合检查，不是 DC 平衡的刻录信号。
public enum BluRayRecordingFrame {
    public static let dcControlBitsPerFrame = BluRaySpec.dcControlBitsPerFrame
    public static let modulatedDataBitsPerFrame = BluRaySpec.modulatedDataBitsPerFrame
    public static let channelBitsPerFrame = BluRaySpec.channelBitsPerFrame

    /// 31 个同步帧在地址单元内的位置表（ISO/IEC 30190 Figure 41 / Table 16）。
    static let syncSequence: [UInt8] = [
        0, 1, 2, 3, 3, 1, 4, 1, 5, 5, 4, 3, 4, 6, 6, 3,
        5, 3, 2, 2, 5, 6, 5, 1, 1, 6, 2, 6, 4, 4, 2,
    ]
    static let syncSignatures: [UInt32] = [
        0b000001, 0b010010, 0b101000, 0b100001, 0b000100, 0b001001, 0b010000,
    ]

    public struct Frame: Sendable, Equatable {
        public let modulationBits: [UInt8]
        public let channelLevels: [UInt8]
        public let usedTermination: Bool
        public var finalChannelLevel: UInt8 { channelLevels.last ?? 0 }
        /// NRZI 电平的数字和（电平 1 记 +1，电平 0 记 −1）。
        public var digitalSum: Int {
            channelLevels.reduce(0) { $0 + ($1 == 0 ? -1 : 1) }
        }
    }

    /// 创建 30 位帧同步。`frameWithinAddressUnit` 为 0…30。
    public static func createFrameSync(
        frameWithinAddressUnit: Int,
        precedingFrameUsedTermination: Bool = false
    ) throws -> [UInt8] {
        guard (0...30).contains(frameWithinAddressUnit) else {
            throw DiscError.encoding("帧同步索引必须在 0…30（当前 \(frameWithinAddressUnit)）")
        }
        let body: UInt32 = 0b0010_1000_0000_0100_0000_0010
        let termination: UInt32 = precedingFrameUsedTermination ? (1 << 23) : 0
        let signature = syncSignatures[Int(syncSequence[frameWithinAddressUnit])]
        let value = ((body | termination) << 6) | signature
        var result = [UInt8](repeating: 0, count: 30)
        for index in 0..<30 {
            result[index] = UInt8((value >> (29 - index)) & 1)
        }
        return result
    }

    /// 在 1240 个数据位中插入 28 个 DC 控制位：先 25 位，之后每 45 位插一个。
    public static func createDataBits(eccFrame: [UInt8], dcControlBits: [UInt8]) throws -> [UInt8] {
        guard eccFrame.count == BluRaySpec.eccBytesPerFrame else {
            throw DiscError.encoding("recording frame 必须以 155 个 ECC 字节开头（当前 \(eccFrame.count)）")
        }
        guard dcControlBits.count == dcControlBitsPerFrame else {
            throw DiscError.encoding("必须提供恰好 28 个 DC 控制位（当前 \(dcControlBits.count)）")
        }
        for bit in dcControlBits where bit > 1 {
            throw DiscError.encoding("DC 控制位必须表示为 0 或 1")
        }
        var result = [UInt8](repeating: 0, count: modulatedDataBitsPerFrame)
        var input = 0
        var output = 0
        for block in 0..<dcControlBitsPerFrame {
            let count = block == 0 ? 25 : 45
            for _ in 0..<count {
                let byte = eccFrame[input / 8]
                result[output] = (byte >> (7 - UInt8(input % 8))) & 1
                output += 1
                input += 1
            }
            result[output] = dcControlBits[block]
            output += 1
        }
        return result
    }

    /// 组装一帧：同步帧 30 位 + 17PP 数据位 1902 位 = 1932 通道位。
    public static func encode(
        eccFrame: [UInt8],
        frameWithinAddressUnit: Int,
        dcControlBits: [UInt8],
        precedingFrameUsedTermination: Bool = false,
        initialChannelLevel: UInt8 = 0
    ) throws -> Frame {
        let sync = try createFrameSync(
            frameWithinAddressUnit: frameWithinAddressUnit,
            precedingFrameUsedTermination: precedingFrameUsedTermination
        )
        let data = try createDataBits(eccFrame: eccFrame, dcControlBits: dcControlBits)
        let encoded = try BluRay17PP.encode(dataBits: data, previousModulationBit: sync[29])
        var modulation = [UInt8](repeating: 0, count: channelBitsPerFrame)
        modulation.replaceSubrange(0..<sync.count, with: sync)
        modulation.replaceSubrange(sync.count..<(sync.count + encoded.modulationBits.count), with: encoded.modulationBits)
        let levels = try BluRay17PP.channelLevels(modulationBits: modulation, initialLevel: initialChannelLevel)
        return Frame(modulationBits: modulation, channelLevels: levels, usedTermination: encoded.usedTermination)
    }
}
