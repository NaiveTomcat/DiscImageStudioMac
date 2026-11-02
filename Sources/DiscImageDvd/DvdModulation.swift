import DiscImageCore
import Foundation

/// EFMPlus 调制在 Sync Frame 边界上的状态。
///
/// - `state`：1…4（ECMA-267 的四个状态）
/// - `dsv`：数字和值（land = +1，pit = −1）
/// - `isLand`：边界处的物理电平（`true` = land = 1 = 白）
public struct DvdModulationBoundary: Equatable, Sendable {
    public var state: Int
    public var dsv: Int
    public var isLand: Bool

    public init(state: Int, dsv: Int, isLand: Bool) {
        self.state = state
        self.dsv = dsv
        self.isLand = isLand
    }

    /// 编码链默认起点：状态 1、DSV 0、land。
    public static let standard = DvdModulationBoundary(state: 1, dsv: 0, isLand: true)

    func validated() throws -> DvdModulationBoundary {
        guard (1...4).contains(state) else {
            throw DiscError.encoding("EFMPlus 状态必须是 1…4（当前 \(state)）")
        }
        return self
    }
}

extension EfmPlusTables {
    /// 主表：`value` × 4 个状态。
    static func mainWord(_ value: UInt8, state: Int) throws -> (word: UInt16, nextState: Int) {
        let index = Int(value) * 4 + (try stateIndex(state))
        return (mainWords[index], Int(mainNextStates[index]))
    }

    /// 替换表：只覆盖 0…87（其余值走主表或 1/4 状态分支）。
    static func substitutionWord(_ value: UInt8, state: Int) throws -> (word: UInt16, nextState: Int) {
        guard value <= 87 else {
            throw DiscError.encoding("EFMPlus 替换表只覆盖 0…87（当前 \(value)）")
        }
        let index = Int(value) * 4 + (try stateIndex(state))
        return (substitutionWords[index], Int(substitutionNextStates[index]))
    }

    /// SYNC 码：`group = state <= 2 ? 0 : 1`，`primary` 选主/副码，`category` 0…7。
    static func syncCode(state: Int, category: Int, primary: Bool) throws -> UInt32 {
        guard (0...7).contains(category) else {
            throw DiscError.encoding("SYNC 类别必须是 0…7（当前 \(category)）")
        }
        let index = try stateIndex(state)
        let group = index <= 1 ? 0 : 1
        return syncCodes[group][primary ? 0 : 1][category]
    }

    private static func stateIndex(_ state: Int) throws -> Int {
        guard (1...4).contains(state) else {
            throw DiscError.encoding("EFMPlus 状态必须是 1…4（当前 \(state)）")
        }
        return state - 1
    }

    /// 与源项目 `EfmPlusTables.SyncCodes` 完全一致的 2×2×8 表。
    static let syncCodes: [[[UInt32]]] = [
        [
            [0x1244_0011, 0x0404_0011, 0x1004_0011, 0x0804_0011,
             0x2004_0011, 0x2244_0011, 0x2484_0011, 0x2444_0011],
            [0x1204_0011, 0x0444_0011, 0x1044_0011, 0x0844_0011,
             0x2044_0011, 0x2204_0011, 0x2084_0011, 0x2404_0011],
        ],
        [
            [0x9204_0011, 0x8444_0011, 0x9044_0011, 0x8244_0011,
             0x8844_0011, 0x8904_0011, 0x9084_0011, 0x8884_0011],
            [0x9244_0011, 0x8404_0011, 0x9004_0011, 0x8204_0011,
             0x8804_0011, 0x8104_0011, 0x9044_0011, 0x8084_0011],
        ],
    ]
}

/// EFMPlus 调制器：每个 Sync Frame 并行维护两条码流，取 `|DSV|` 小者。
///
/// 逐行移植自源项目 `EfmPlusEncoder.cs`（含三处细节，改之前请先读源码）：
/// 1. 每个 91 字节 Sync Frame 都从同一个入口边界重新开出 Stream1/Stream2，
///    两条流的差别只在 SYNC 主码/副码；
/// 2. `value <= 87` 时，一条流走主表、另一条走替换表；
/// 3. 结束时若胜者 `|DSV| > 63`，尝试把 SYNC 主/副码换成另一个再比一次。
struct EfmPlusEncoder {
    /// 一条候选码流（1488 个 transition 位 + 状态 + DSV + 电平）。
    struct StreamCandidate {
        var nrz = [UInt8](repeating: 0, count: DvdConstants.bitsPerSyncFrame)
        var length = 0
        var state = 1
        var dsv = 0
        var isLand = true
        var syncPrimary = true

        mutating func initialize(boundary: DvdModulationBoundary, sync: UInt32, primary: Bool) {
            length = 0
            state = boundary.state
            dsv = boundary.dsv
            isLand = boundary.isLand
            syncPrimary = primary
            appendBits(sync, count: 32)
            // 每个 SYNC 码都以 ONE 结尾，因此下一个状态恒为 1。
            state = 1
        }

        mutating func copy(from source: StreamCandidate) {
            nrz.replaceSubrange(0..<source.length, with: source.nrz[0..<source.length])
            length = source.length
            state = source.state
            dsv = source.dsv
            isLand = source.isLand
            syncPrimary = source.syncPrimary
        }

        mutating func append(_ word: UInt16, nextState: Int) throws {
            guard canAppend(word) else {
                throw DiscError.encoding("EFMPlus 码字会违反 RLL(2,10) 边界（state \(state)）")
            }
            appendBits(UInt32(word), count: 16)
            state = nextState
        }

        func canAppend(_ word: UInt16) -> Bool {
            var trailingZeros = 0
            var index = length - 1
            while index >= 0 && nrz[index] == 0 {
                trailingZeros += 1
                index -= 1
            }
            var leadingZeros = 0
            var bit = 15
            while bit >= 0 && ((word >> UInt16(bit)) & 1) == 0 {
                leadingZeros += 1
                bit -= 1
            }
            let combined = trailingZeros + leadingZeros
            return combined >= 2 && combined <= 10
        }

        mutating func appendBits(_ bits: UInt32, count: Int) {
            var bit = count - 1
            while bit >= 0 {
                let transition = UInt8((bits >> UInt32(bit)) & 1)
                nrz[length] = transition
                length += 1
                if transition != 0 {
                    isLand.toggle()
                }
                dsv += isLand ? 1 : -1
                bit -= 1
            }
        }
    }

    /// 调制一个 Sync Frame，把物理电平写进 `levels[offset..<offset+1488]`，返回出口边界。
    func encodeSyncFrame(
        bytes: ArraySlice<UInt8>,
        syncCategory: Int,
        input: DvdModulationBoundary,
        levels: inout [UInt8],
        offset: Int
    ) throws -> DvdModulationBoundary {
        precondition(bytes.count == DvdConstants.bytesPerSyncFrame)
        precondition(offset >= 0 && offset + DvdConstants.bitsPerSyncFrame <= levels.count)
        let boundary = try input.validated()

        var stream1 = StreamCandidate()
        var stream2 = StreamCandidate()
        stream1.initialize(
            boundary: boundary,
            sync: try EfmPlusTables.syncCode(state: boundary.state, category: syncCategory, primary: true),
            primary: true
        )
        stream2.initialize(
            boundary: boundary,
            sync: try EfmPlusTables.syncCode(state: boundary.state, category: syncCategory, primary: false),
            primary: false
        )

        for value in bytes {
            if value <= 87 {
                let selected = Self.select(stream1, stream2)
                stream1 = selected
                stream2 = selected
                let main = try EfmPlusTables.mainWord(value, state: selected.state)
                let substitution = try EfmPlusTables.substitutionWord(value, state: selected.state)
                try stream1.append(main.word, nextState: main.nextState)
                try stream2.append(substitution.word, nextState: substitution.nextState)
                continue
            }

            let firstCanBranch = Self.hasTwoStateOneFourRepresentations(value, stream: stream1)
            let secondCanBranch = Self.hasTwoStateOneFourRepresentations(value, stream: stream2)
            if firstCanBranch && secondCanBranch {
                let selected = Self.select(stream1, stream2)
                stream1 = selected
                stream2 = selected
                try Self.appendStateOneAndFourAlternatives(value, stream1: &stream1, stream2: &stream2)
            } else if firstCanBranch || secondCanBranch {
                let eligible = firstCanBranch ? stream1 : stream2
                let other = firstCanBranch ? stream2 : stream1
                let chooseEligible = abs(eligible.dsv) < abs(other.dsv)
                    || (abs(eligible.dsv) == abs(other.dsv) && firstCanBranch)
                if chooseEligible {
                    stream1 = eligible
                    stream2 = eligible
                    try Self.appendStateOneAndFourAlternatives(value, stream1: &stream1, stream2: &stream2)
                } else {
                    try Self.appendMain(value, stream: &stream1)
                    try Self.appendMain(value, stream: &stream2)
                }
            } else {
                try Self.appendMain(value, stream: &stream1)
                try Self.appendMain(value, stream: &stream2)
            }
        }

        var winner = Self.select(stream1, stream2)
        if winner.dsv > 63 || winner.dsv < -64 {
            let alternatePrimary = !winner.syncPrimary
            var alternateNrz = winner.nrz
            Self.writeBits(
                try EfmPlusTables.syncCode(
                    state: boundary.state,
                    category: syncCategory,
                    primary: alternatePrimary
                ),
                count: 32,
                into: &alternateNrz,
                at: 0
            )
            let alternateBoundary = Self.replay(alternateNrz, input: boundary)
            if abs(alternateBoundary.dsv) < abs(winner.dsv) {
                winner.nrz = alternateNrz
                winner.dsv = alternateBoundary.dsv
                winner.isLand = alternateBoundary.isLand
                winner.syncPrimary = alternatePrimary
            }
        }

        let output = Self.replay(winner.nrz, input: boundary, levels: &levels, at: offset)
        return DvdModulationBoundary(state: winner.state, dsv: output.dsv, isLand: output.isLand)
    }

    // MARK: - 分支与重放

    private static func appendStateOneAndFourAlternatives(
        _ value: UInt8,
        stream1: inout StreamCandidate,
        stream2: inout StreamCandidate
    ) throws {
        let stateOne = try EfmPlusTables.mainWord(value, state: 1)
        let stateFour = try EfmPlusTables.mainWord(value, state: 4)
        guard stream1.canAppend(stateOne.word), stream2.canAppend(stateFour.word) else {
            throw DiscError.encoding("EFMPlus 状态 1/4 分支非法")
        }
        try stream1.append(stateOne.word, nextState: stateOne.nextState)
        try stream2.append(stateFour.word, nextState: stateFour.nextState)
    }

    private static func hasTwoStateOneFourRepresentations(
        _ value: UInt8,
        stream: StreamCandidate
    ) -> Bool {
        guard stream.state == 1 || stream.state == 4 else { return false }
        guard let stateOne = try? EfmPlusTables.mainWord(value, state: 1),
              let stateFour = try? EfmPlusTables.mainWord(value, state: 4) else {
            return false
        }
        return stream.canAppend(stateOne.word) && stream.canAppend(stateFour.word)
    }

    private static func appendMain(_ value: UInt8, stream: inout StreamCandidate) throws {
        let main = try EfmPlusTables.mainWord(value, state: stream.state)
        try stream.append(main.word, nextState: main.nextState)
    }

    private static func select(_ stream1: StreamCandidate, _ stream2: StreamCandidate) -> StreamCandidate {
        abs(stream1.dsv) <= abs(stream2.dsv) ? stream1 : stream2
    }

    private static func writeBits(_ bits: UInt32, count: Int, into destination: inout [UInt8], at offset: Int) {
        var bit = count - 1
        var index = 0
        while bit >= 0 {
            destination[offset + index] = UInt8((bits >> UInt32(bit)) & 1)
            bit -= 1
            index += 1
        }
    }

    /// 把 transition 位串换算成物理电平（NRZI），可选写入输出。
    private static func replay(
        _ nrz: [UInt8],
        input: DvdModulationBoundary,
        levels: inout [UInt8],
        at offset: Int
    ) -> DvdModulationBoundary {
        var level = input.isLand
        var dsv = input.dsv
        for index in 0..<DvdConstants.bitsPerSyncFrame {
            if nrz[index] != 0 {
                level.toggle()
            }
            levels[offset + index] = level ? 1 : 0
            dsv += level ? 1 : -1
        }
        return DvdModulationBoundary(state: input.state, dsv: dsv, isLand: level)
    }

    /// 只重放、不写输出（用于 SYNC 替换的候选比较）。
    private static func replay(_ nrz: [UInt8], input: DvdModulationBoundary) -> DvdModulationBoundary {
        var level = input.isLand
        var dsv = input.dsv
        for index in 0..<DvdConstants.bitsPerSyncFrame {
            if nrz[index] != 0 {
                level.toggle()
            }
            dsv += level ? 1 : -1
        }
        return DvdModulationBoundary(state: input.state, dsv: dsv, isLand: level)
    }
}
