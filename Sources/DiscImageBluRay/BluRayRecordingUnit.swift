import Foundation
import DiscImageCore

/// BD-R recording unit（RUB）的通道位模拟：run-in + 496 帧 + run-out（可选 Guard_3）。
///
/// 长度：2760（run-in）+ 496 × 1932（物理簇）+ 1104（run-out）= **962,136** 通道位。
/// run-in/run-out 里的 Guard / PrA / PoA 图案与同步帧来自源项目
/// `BluRayRecordingUnitEncoder.cs`（ISO/IEC 30190 §14）。
///
/// 返回的是「每个通道位一个字节」的调制度序列与 NRZI 电平序列，不是盘面反射率，
/// 也不是驱动器命令。APC、写脉冲、wobble/ADIP 与整盘管理区都属刻录机/介质范畴。
public enum BluRayRecordingUnit {
    public static let runInChannelBits = BluRaySpec.runInChannelBits
    public static let physicalClusterChannelBits = BluRaySpec.physicalClusterChannelBits
    public static let runOutChannelBits = BluRaySpec.runOutChannelBits
    public static let recordingUnitChannelBits = BluRaySpec.channelBitsPerRecordingUnit
    public static let guard3ChannelBits = BluRaySpec.guard3ChannelBits

    /// run-in/run-out 使用的 20 位基础图案。
    static let guardPattern: [UInt8] = [0, 1, 0, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0]

    public struct Result: Sendable {
        public let firstPhysicalSectorNumber: UInt32
        /// 每个通道位一个 0/1（1 = 翻转）。
        public let modulationBits: [UInt8]
        /// NRZI 电平序列（0/1）。
        public let channelLevels: [UInt8]
        /// 496 帧 × 28 个 DC 控制位。
        public let dcControlBits: [UInt8]
        public let includesGuard3: Bool
        public let initialChannelLevel: UInt8
        public let finalChannelLevel: UInt8
        public let finalDigitalSum: Int
        /// 贪心策略的局部次优决策数（仅在 `computeDiagnostics` 时统计，否则为 0）。
        public let suboptimalDCControlDecisions: Int
    }

    /// 从 65,536 个用户字节生成一个完整 RUB。
    public static func encode(
        userData: [UInt8],
        firstPhysicalSectorNumber: UInt32,
        addressFlags: [UInt8] = [],
        userControlData: [UInt8] = [],
        appendGuard3: Bool = false,
        initialChannelLevel: UInt8 = 0,
        initialDigitalSum: Int = 0,
        computeDiagnostics: Bool = false
    ) throws -> Result {
        let ecc = try BluRayECCEncoder.encode(
            userData: userData,
            firstPhysicalSectorNumber: firstPhysicalSectorNumber,
            addressFlags: addressFlags,
            userControlData: userControlData
        )
        return try encodeCluster(
            eccCluster: ecc,
            firstPhysicalSectorNumber: firstPhysicalSectorNumber,
            appendGuard3: appendGuard3,
            initialChannelLevel: initialChannelLevel,
            initialDigitalSum: initialDigitalSum,
            computeDiagnostics: computeDiagnostics
        )
    }

    /// 从 496 × 155 的 ECC 簇生成一个完整 RUB。
    public static func encodeCluster(
        eccCluster: [UInt8],
        firstPhysicalSectorNumber: UInt32,
        appendGuard3: Bool = false,
        initialChannelLevel: UInt8 = 0,
        initialDigitalSum: Int = 0,
        computeDiagnostics: Bool = false
    ) throws -> Result {
        guard eccCluster.count == BluRaySpec.eccClusterBytes else {
            throw DiscError.encoding("ECC 簇必须是 496 行 × 155 字节（当前 \(eccCluster.count)）")
        }
        try BluRayECCEncoder.validatePSN(firstPhysicalSectorNumber)
        guard initialChannelLevel <= 1 else {
            throw DiscError.encoding("initialChannelLevel 只能是 0 或 1")
        }

        let total = recordingUnitChannelBits + (appendGuard3 ? guard3ChannelBits : 0)
        var modulation = [UInt8](repeating: 0, count: total)
        var levels = [UInt8](repeating: 0, count: total)
        var controls = [UInt8](repeating: 0, count: BluRaySpec.recordingFrames * BluRaySpec.dcControlBitsPerFrame)
        var cursor = 0
        var level = initialChannelLevel
        var sum = initialDigitalSum

        func append(_ bits: [UInt8]) {
            for transition in bits {
                modulation[cursor] = transition
                level ^= transition
                levels[cursor] = level
                cursor += 1
                sum += level == 0 ? -1 : 1
            }
        }
        func appendGuard(_ repeats: Int) {
            for _ in 0..<repeats { append(guardPattern) }
        }

        // run-in：Guard_1（1100 位）+ PrA 前 1540 位 + FS4 + Guard + FS6 + Guard。
        appendGuard(55)
        appendGuard(77)
        append(try BluRayRecordingFrame.createFrameSync(frameWithinAddressUnit: 6))
        appendGuard(2)
        append(try BluRayRecordingFrame.createFrameSync(frameWithinAddressUnit: 13))
        appendGuard(1)
        guard cursor == runInChannelBits else {
            throw DiscError.encoding("run-in 长度异常（\(cursor) ≠ \(runInChannelBits)）")
        }

        var previousTermination = false
        var terminationFlags = [Bool](repeating: false, count: BluRaySpec.recordingFrames)
        var startingDigitalSums = [Int](repeating: 0, count: BluRaySpec.recordingFrames)
        for frame in 0..<BluRaySpec.recordingFrames {
            let next: [UInt8] = frame == BluRaySpec.recordingFrames - 1
                ? []
                : Array(eccCluster[((frame + 1) * BluRaySpec.eccBytesPerFrame)..<((frame + 2) * BluRaySpec.eccBytesPerFrame)])
            let current = Array(eccCluster[(frame * BluRaySpec.eccBytesPerFrame)..<((frame + 1) * BluRaySpec.eccBytesPerFrame)])
            startingDigitalSums[frame] = sum
            terminationFlags[frame] = previousTermination
            let balanced = try BluRayGreedyDCControl.encode(
                eccFrame: current,
                frameWithinAddressUnit: frame % 31,
                nextEccFrame: next,
                precedingFrameUsedTermination: previousTermination,
                initialChannelLevel: level,
                initialDigitalSum: sum
            )
            let controlBase = frame * BluRaySpec.dcControlBitsPerFrame
            controls.replaceSubrange(
                controlBase..<(controlBase + BluRaySpec.dcControlBitsPerFrame),
                with: balanced.dcControlBits
            )
            append(balanced.frame.modulationBits)
            previousTermination = balanced.frame.usedTermination
        }

        // PoA：FS0 + 9T 停止图案 + Guard_2。
        append(try BluRayRecordingFrame.createFrameSync(frameWithinAddressUnit: 0, precedingFrameUsedTermination: previousTermination))
        var stopPattern = [UInt8](repeating: 0, count: 54)
        var stopIndex = 1
        while stopIndex < stopPattern.count {
            stopPattern[stopIndex] = 1
            stopIndex += 9
        }
        append(stopPattern)
        appendGuard(24)
        appendGuard(27)
        if appendGuard3 { appendGuard(27) }
        guard cursor == total else {
            throw DiscError.encoding("recording unit 长度异常（\(cursor) ≠ \(total)）")
        }

        var suboptimal = 0
        if computeDiagnostics {
            for frame in 0..<BluRaySpec.recordingFrames {
                let current = Array(eccCluster[(frame * BluRaySpec.eccBytesPerFrame)..<((frame + 1) * BluRaySpec.eccBytesPerFrame)])
                let hasNext = frame < BluRaySpec.recordingFrames - 1
                let next = hasNext
                    ? Array(eccCluster[((frame + 1) * BluRaySpec.eccBytesPerFrame)..<((frame + 2) * BluRaySpec.eccBytesPerFrame)])
                    : []
                let nextControls = hasNext
                    ? Array(controls[((frame + 1) * BluRaySpec.dcControlBitsPerFrame)..<((frame + 2) * BluRaySpec.dcControlBitsPerFrame)])
                    : []
                let controlBase = frame * BluRaySpec.dcControlBitsPerFrame
                let frameControls = Array(controls[controlBase..<(controlBase + BluRaySpec.dcControlBitsPerFrame)])
                suboptimal += try BluRayGreedyDCControl.countSuboptimalDecisions(
                    eccFrame: current,
                    frameWithinAddressUnit: frame % 31,
                    dcControlBits: frameControls,
                    nextEccFrame: next,
                    nextDCControlBits: nextControls,
                    precedingFrameUsedTermination: terminationFlags[frame],
                    initialChannelLevel: levels[runInChannelBits + frame * BluRaySpec.channelBitsPerFrame - 1],
                    initialDigitalSum: startingDigitalSums[frame]
                )
            }
        }

        return Result(
            firstPhysicalSectorNumber: firstPhysicalSectorNumber,
            modulationBits: modulation,
            channelLevels: levels,
            dcControlBits: controls,
            includesGuard3: appendGuard3,
            initialChannelLevel: initialChannelLevel,
            finalChannelLevel: level,
            finalDigitalSum: sum,
            suboptimalDCControlDecisions: suboptimal
        )
    }

    /// 数据侧 496 帧的调制度（去掉 run-in/out，长度 958,272）。
    public static func dataModulationBits(of result: Result) -> [UInt8] {
        Array(result.modulationBits[runInChannelBits..<(runInChannelBits + physicalClusterChannelBits)])
    }
}

/// 调制位串的游程统计（诊断用，不参与生成）。
///
/// 统计「相邻 modulation ONE 之间的完整间隔」：两个 1 之间的 0 的个数。
/// 3T 表示间隔正好 3 个通道位（即 NRZI 电平连续 3 位不变）。
public enum BluRayRunStatistics {
    /// 返回 游程长度 → 次数。区间以相邻 ONE 为界，首尾未闭合的游程不计。
    public static func gapHistogram(_ modulationBits: [UInt8]) -> [Int: Int] {
        var histogram: [Int: Int] = [:]
        var previous: Int?
        for (index, bit) in modulationBits.enumerated() where bit == 1 {
            if let last = previous {
                histogram[index - last, default: 0] += 1
            }
            previous = index
        }
        return histogram
    }

    /// 统计间隔恰好为 `length` 的次数。
    public static func countGaps(ofLength length: Int, in modulationBits: [UInt8]) -> Int {
        var count = 0
        var previous: Int?
        for (index, bit) in modulationBits.enumerated() where bit == 1 {
            if let last = previous, index - last == length { count += 1 }
            previous = index
        }
        return count
    }
}
