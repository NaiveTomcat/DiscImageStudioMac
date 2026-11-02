import Foundation
import DiscImageCore

/// 28 个 DC 控制位的确定性前视贪心选择（ISO/IEC 30190:2021 §13.17.3 的诊断实现）。
///
/// 做法：逐位尝试 0/1，把帧编码到「当前控制位 + 2」段结束处，比较该段的
/// |DSV|；第 28 个控制位额外把下一帧的前 69 个通道位算进来（末帧则用 PoA 的
/// FS0 + 9T 停止图案）。
///
/// 这是**贪心诊断策略**：尚未决定的后续控制位一律暂置 0，因此它不保证标准要求的
/// 最终 DC 最优性，也不代表刻录机专有的写策略。`countSuboptimalDecisions` 用来
/// 报告这种「后续位定案后前一个选择会变差」的情况。
///
/// 实现说明：17PP 是确定性的前缀码。对第 c 个控制位的两种取值，帧前缀
/// （直到最后一个不跨过该控制位的码字边界）完全一致，因此不必像源项目那样
/// 对整个 1268 位数据重新编码：这里从缓存边界继续编码到 `(c+2)×69` 位为止。
/// 逐位结果与「整帧重编码」等价（用源项目文档的整簇 3T/6T 统计值交叉验证）。
public enum BluRayGreedyDCControl {
    public struct BalancedFrame: Sendable {
        public let frame: BluRayRecordingFrame.Frame
        public let dcControlBits: [UInt8]
        public let finalDigitalSum: Int
    }

    /// 编码一帧并贪心选择 28 个 DC 控制位。
    public static func encode(
        eccFrame: [UInt8],
        frameWithinAddressUnit: Int,
        nextEccFrame: [UInt8] = [],
        precedingFrameUsedTermination: Bool = false,
        initialChannelLevel: UInt8 = 0,
        initialDigitalSum: Int = 0
    ) throws -> BalancedFrame {
        guard nextEccFrame.isEmpty || nextEccFrame.count == BluRaySpec.eccBytesPerFrame else {
            throw DiscError.encoding("前视用的下一帧必须是 155 个 ECC 字节")
        }
        let scratch = try BluRayFrameScratch(
            eccFrame: eccFrame,
            frameWithinAddressUnit: frameWithinAddressUnit,
            precedingFrameUsedTermination: precedingFrameUsedTermination,
            initialChannelLevel: initialChannelLevel
        )

        // 先推进到第一个控制位之前的「安全」码字边界。
        guard let firstControlIndex = scratch.controlDataIndex(0) else {
            throw DiscError.encoding("DC 控制位索引异常")
        }
        try advanceToSafeBoundary(scratch, controlIndex: firstControlIndex)

        var controls = [UInt8](repeating: 0, count: BluRaySpec.dcControlBitsPerFrame)
        for control in 0..<controls.count {
            guard let dataIndex = scratch.controlDataIndex(control) else {
                throw DiscError.encoding("DC 控制位索引异常（\(control)）")
            }
            let saved = scratch.saveState()
            var scores = [Int](repeating: 0, count: 2)
            for candidate in 0..<2 {
                scratch.restoreState(saved)
                scratch.dataBits[dataIndex] = UInt8(candidate)
                let endpoint = min((control + 2) * 69, BluRaySpec.channelBitsPerFrame)
                scratch.run(untilOutputAtLeast: endpoint)
                scores[candidate] = try scratch.score(
                    control: control,
                    initialDigitalSum: initialDigitalSum,
                    prefixSum: saved.levelSum,
                    prefixProduced: saved.produced,
                    nextEccFrame: nextEccFrame,
                    nextDCControlBits: [],
                    frameWithinAddressUnit: frameWithinAddressUnit
                )
            }
            let chosen: UInt8 = scores[1] < scores[0] ? 1 : 0
            controls[control] = chosen
            scratch.restoreState(saved)
            scratch.dataBits[dataIndex] = chosen
            if control < controls.count - 1 {
                guard let nextControlIndex = scratch.controlDataIndex(control + 1) else {
                    throw DiscError.encoding("DC 控制位索引异常（\(control + 1)）")
                }
                try advanceToSafeBoundary(scratch, controlIndex: nextControlIndex)
            } else {
                scratch.runToEnd()
            }
        }
        guard scratch.source == scratch.dataBits.count,
              scratch.produced == BluRaySpec.channelBitsPerFrame else {
            throw DiscError.encoding("recording frame 编码未完整结束")
        }
        let frame = scratch.makeFrame()
        return BalancedFrame(
            frame: frame,
            dcControlBits: controls,
            finalDigitalSum: initialDigitalSum + frame.digitalSum
        )
    }

    /// 17PP 的 Figure 41 替换规则最多向前看 14 个数据位（`ConvertNext` 从
    /// `source + 6` 起最多再读 8 位）。因此要独立评估第 c 个 DC 控制位，必须回退到
    /// 距它至少 16 位之前的码字边界：更早的码字不会读到该控制位。
    static let lookaheadGuard = 16

    /// 把编码器推进到 `controlIndex − lookaheadGuard` 之前最近的码字边界。
    ///
    /// 只有**完整结束在安全线之前**的码字才会被 `step()`；它们的向前看不会触及
    /// 待评估的控制位，所以这一段调制位对控制位取 0 还是 1 都相同。
    static func advanceToSafeBoundary(_ scratch: BluRayFrameScratch, controlIndex: Int) throws {
        let target = max(0, controlIndex - lookaheadGuard)
        while scratch.source < scratch.dataBits.count,
              scratch.source + scratch.peekWordLength() <= target {
            try scratch.step()
        }
    }

    /// 统计「后续位定案后会翻转」的局部次优决策数；0 不代表标准合规。
    public static func countSuboptimalDecisions(
        eccFrame: [UInt8],
        frameWithinAddressUnit: Int,
        dcControlBits: [UInt8],
        nextEccFrame: [UInt8] = [],
        nextDCControlBits: [UInt8] = [],
        precedingFrameUsedTermination: Bool = false,
        initialChannelLevel: UInt8 = 0,
        initialDigitalSum: Int = 0
    ) throws -> Int {
        guard nextEccFrame.isEmpty == nextDCControlBits.isEmpty else {
            throw DiscError.encoding("下一帧与它的 DC 控制位必须成对提供")
        }
        if !nextEccFrame.isEmpty {
            guard nextEccFrame.count == BluRaySpec.eccBytesPerFrame,
                  nextDCControlBits.count == BluRaySpec.dcControlBitsPerFrame else {
                throw DiscError.encoding("前视的下一帧必须是 155 字节 ECC + 28 个 DC 控制位")
            }
        }
        var controls = dcControlBits
        let actual = try BluRayRecordingFrame.encode(
            eccFrame: eccFrame,
            frameWithinAddressUnit: frameWithinAddressUnit,
            dcControlBits: controls,
            precedingFrameUsedTermination: precedingFrameUsedTermination,
            initialChannelLevel: initialChannelLevel
        )
        var count = 0
        for control in 0..<controls.count {
            controls[control] ^= 1
            let alternate = try BluRayRecordingFrame.encode(
                eccFrame: eccFrame,
                frameWithinAddressUnit: frameWithinAddressUnit,
                dcControlBits: controls,
                precedingFrameUsedTermination: precedingFrameUsedTermination,
                initialChannelLevel: initialChannelLevel
            )
            controls[control] ^= 1
            let alternateScore = try slowScore(
                frame: alternate,
                control: control,
                nextEccFrame: nextEccFrame,
                nextDCControlBits: nextDCControlBits,
                frameWithinAddressUnit: frameWithinAddressUnit,
                initialDigitalSum: initialDigitalSum
            )
            let actualScore = try slowScore(
                frame: actual,
                control: control,
                nextEccFrame: nextEccFrame,
                nextDCControlBits: nextDCControlBits,
                frameWithinAddressUnit: frameWithinAddressUnit,
                initialDigitalSum: initialDigitalSum
            )
            if alternateScore < actualScore { count += 1 }
        }
        return count
    }

    /// 参考实现：对整帧逐位求 |DSV|（仅用于诊断函数与交叉验证）。
    static func slowScore(
        frame: BluRayRecordingFrame.Frame,
        control: Int,
        nextEccFrame: [UInt8],
        nextDCControlBits: [UInt8],
        frameWithinAddressUnit: Int,
        initialDigitalSum: Int
    ) throws -> Int {
        let endpoint = min((control + 2) * 69, BluRaySpec.channelBitsPerFrame)
        var sum = initialDigitalSum
        for index in 0..<endpoint {
            sum += frame.channelLevels[index] == 0 ? -1 : 1
        }
        if control == BluRaySpec.dcControlBitsPerFrame - 1 {
            let nextModulation = try nextFrameLookahead(
                nextEccFrame: nextEccFrame,
                nextDCControlBits: nextDCControlBits,
                frameWithinAddressUnit: frameWithinAddressUnit,
                usedTermination: frame.usedTermination
            )
            var level = frame.finalChannelLevel
            for transition in nextModulation {
                level ^= transition
                sum += level == 0 ? -1 : 1
            }
        }
        return abs(sum)
    }

    /// 第 28 个控制位的 69 位前视：下一帧的同步帧 + 前 39 个 17PP 位。
    /// 没有下一帧时使用 PoA 的 FS0 + 9T 停止图案。
    static func nextFrameLookahead(
        nextEccFrame: [UInt8],
        nextDCControlBits: [UInt8],
        frameWithinAddressUnit: Int,
        usedTermination: Bool
    ) throws -> [UInt8] {
        var nextModulation = [UInt8](repeating: 0, count: 69)
        if !nextEccFrame.isEmpty {
            let nextData = try BluRayRecordingFrame.createDataBits(
                eccFrame: nextEccFrame,
                dcControlBits: nextDCControlBits.isEmpty
                    ? [UInt8](repeating: 0, count: BluRaySpec.dcControlBitsPerFrame)
                    : nextDCControlBits
            )
            let nextSync = try BluRayRecordingFrame.createFrameSync(
                frameWithinAddressUnit: (frameWithinAddressUnit + 1) % 31,
                precedingFrameUsedTermination: usedTermination
            )
            let encoded = try BluRay17PP.encode(dataBits: nextData, previousModulationBit: nextSync[29])
            nextModulation.replaceSubrange(0..<30, with: nextSync)
            nextModulation.replaceSubrange(30..<69, with: encoded.modulationBits[0..<39])
        } else {
            let nextSync = try BluRayRecordingFrame.createFrameSync(
                frameWithinAddressUnit: 0,
                precedingFrameUsedTermination: usedTermination
            )
            nextModulation.replaceSubrange(0..<30, with: nextSync)
            var index = 31
            while index < nextModulation.count {
                nextModulation[index] = 1
                index += 9
            }
        }
        return nextModulation
    }
}

/// 单帧编码的工作区：预分配缓冲 + 可保存/恢复的编码器状态。
///
/// 17PP 是前缀码，保存 (source, produced, previous, level, terminated) 就等于保存了
/// 编码器状态；从边界继续编码与从头重编码得到的通道位完全一致。
final class BluRayFrameScratch {
    struct State {
        let source: Int
        let produced: Int
        let previous: UInt8
        let level: UInt8
        let levelSum: Int
        let terminated: Bool
    }

    var dataBits: [UInt8]
    var modulation = [UInt8](repeating: 0, count: BluRaySpec.channelBitsPerFrame)
    var levels = [UInt8](repeating: 0, count: BluRaySpec.channelBitsPerFrame)
    private(set) var source = 0
    private(set) var produced = 30
    private(set) var previous: UInt8
    private(set) var level: UInt8
    /// Σ（电平=0 记 −1，电平=1 记 +1），只累计已产出的通道位。
    private(set) var levelSum = 0
    private(set) var terminated = false

    init(
        eccFrame: [UInt8],
        frameWithinAddressUnit: Int,
        precedingFrameUsedTermination: Bool,
        initialChannelLevel: UInt8
    ) throws {
        dataBits = try BluRayRecordingFrame.createDataBits(
            eccFrame: eccFrame,
            dcControlBits: [UInt8](repeating: 0, count: BluRaySpec.dcControlBitsPerFrame)
        )
        let sync = try BluRayRecordingFrame.createFrameSync(
            frameWithinAddressUnit: frameWithinAddressUnit,
            precedingFrameUsedTermination: precedingFrameUsedTermination
        )
        var current = initialChannelLevel
        for index in 0..<sync.count {
            modulation[index] = sync[index]
            current ^= sync[index]
            levels[index] = current
            levelSum += current == 0 ? -1 : 1
        }
        level = current
        previous = sync[sync.count - 1]
    }

    func saveState() -> State {
        State(
            source: source,
            produced: produced,
            previous: previous,
            level: level,
            levelSum: levelSum,
            terminated: terminated
        )
    }

    func restoreState(_ state: State) {
        source = state.source
        produced = state.produced
        previous = state.previous
        level = state.level
        levelSum = state.levelSum
        terminated = state.terminated
    }

    /// 第 c 个 DC 控制位在 dataBits 里的下标：先 25 位数据，之后每 45 位数据插一个。
    func controlDataIndex(_ control: Int) -> Int? {
        let index = 25 + control * 46
        return index < dataBits.count ? index : nil
    }

    func peekWordLength() -> Int {
        guard source < dataBits.count else { return 0 }
        return BluRay17PP.nextWord(dataBits, from: source, previous: previous).dataLength
    }

    func step() throws {
        guard source < dataBits.count else { return }
        let word = BluRay17PP.nextWord(dataBits, from: source, previous: previous)
        let channelLength = word.dataLength / 2 * 3
        var bit = channelLength - 1
        while bit >= 0 {
            let transition = UInt8((word.channelValue >> bit) & 1)
            modulation[produced] = transition
            level ^= transition
            levels[produced] = level
            levelSum += level == 0 ? -1 : 1
            produced += 1
            bit -= 1
        }
        previous = modulation[produced - 1]
        source += word.dataLength
        terminated = word.isTerminating
    }

    func run(untilOutputAtLeast limit: Int) {
        while produced < limit && source < dataBits.count {
            try? step()
        }
    }

    func runToEnd() {
        while source < dataBits.count {
            try? step()
        }
    }

    /// 当前段结束处的 |DSV|；第 28 个控制位再看下一帧的 69 位。
    func score(
        control: Int,
        initialDigitalSum: Int,
        prefixSum: Int,
        prefixProduced: Int,
        nextEccFrame: [UInt8],
        nextDCControlBits: [UInt8],
        frameWithinAddressUnit: Int
    ) throws -> Int {
        let endpoint = min((control + 2) * 69, BluRaySpec.channelBitsPerFrame)
        // 前缀的 DSV 已经缓存，只需累加本次候选运行新产生的通道位。
        var sum = initialDigitalSum + prefixSum
        var index = prefixProduced
        while index < endpoint {
            sum += levels[index] == 0 ? -1 : 1
            index += 1
        }
        if control == BluRaySpec.dcControlBitsPerFrame - 1 {
            let nextModulation = try BluRayGreedyDCControl.nextFrameLookahead(
                nextEccFrame: nextEccFrame,
                nextDCControlBits: nextDCControlBits,
                frameWithinAddressUnit: frameWithinAddressUnit,
                usedTermination: terminated
            )
            var current = levels[BluRaySpec.channelBitsPerFrame - 1]
            for transition in nextModulation {
                current ^= transition
                sum += current == 0 ? -1 : 1
            }
        }
        return abs(sum)
    }

    func makeFrame() -> BluRayRecordingFrame.Frame {
        BluRayRecordingFrame.Frame(
            modulationBits: Array(modulation[0..<BluRaySpec.channelBitsPerFrame]),
            channelLevels: Array(levels[0..<BluRaySpec.channelBitsPerFrame]),
            usedTermination: terminated
        )
    }
}
