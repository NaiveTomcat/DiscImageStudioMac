import DiscImageCore
import Foundation

/// `ToneDither.phase` 的内联副本。
///
/// 与 `DiscImageCore.ToneDither.phase` **逐位一致**（同一串 32 位哈希），
/// 由 `CdFastPathEquivalenceTests` 守护。放进热点循环是为了避免每个字节一次
/// 跨模块函数调用；Core 那边的定义才是唯一语义来源。
@inline(__always)
func cdDitherPhase(_ sampleIndex: Int64) -> Double {
    var value = UInt32(truncatingIfNeeded: sampleIndex) &* 2_654_435_761
    value ^= value >> 16
    value &*= 0x7FEB_352D
    value ^= value >> 15
    value &*= 0x846C_A68B
    value ^= value >> 16
    return Double(value) / 4_294_967_296.0
}

/// 影调查找表：把 `ToneProfile.levelIndex` 的判定预计算成 256 项表。
///
/// 原实现每个字节都要走 `adjustedGray`（sRGB 反伽马 + 亮度平移 + 取整）再做抖动判定；
/// 其中「灰度 → 调整后灰度」只取决于灰度本身，可以预先算成 256 项。
/// 抖动相位仍然逐字节按**逻辑字节序号**算（`cdDitherPhase`），运算顺序与
/// `ToneProfile.useWhite` / `levelIndex` 完全一致，因此每个字节的调色板结果不变。
///
/// 判定分支与 Core 对齐：
/// - 2 阶：`isLegacyBinary` 时是历史硬阈值 128；否则 `adjusted[g] >= 128 + s·255·(phase−0.5)`；
/// - 4 阶：无抖动/无亮度/无伽马时是 `gray >> 6`；否则对 `normalized[g] + s·(phase−0.5)` 四舍五入。
final class CdToneLUT: @unchecked Sendable {
    let levels: Int
    let isLegacyBinary: Bool
    let strength: Double
    let usesFourLevels: Bool
    /// 4 阶且抖动/亮度/伽马全为 0：直接 `gray >> 6`，不用相位。
    let fourLevelFlat: Bool

    private let palette: UnsafeMutablePointer<UInt8>
    private let adjusted: UnsafeMutablePointer<Double>
    private let normalized: UnsafeMutablePointer<Double>

    init(tone: ToneProfile) {
        self.usesFourLevels = tone.levels == ToneProfile.fourLevels
        self.levels = usesFourLevels ? ToneProfile.fourLevels : ToneProfile.twoLevels
        self.isLegacyBinary = tone.isLegacyBinary
        self.strength = min(max(tone.ditherStrength, 0), 1)
        self.fourLevelFlat = tone.ditherStrength <= 0
            && tone.brightness == 0
            && tone.srgbLinearization <= 0

        palette = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        let source = CdToneMapping.palette(levels: levels)
        for index in 0..<4 {
            palette[index] = index < source.count ? source[index] : source[source.count - 1]
        }

        adjusted = UnsafeMutablePointer<Double>.allocate(capacity: 256)
        normalized = UnsafeMutablePointer<Double>.allocate(capacity: 256)
        for gray in 0..<256 {
            let value = Double(tone.adjustedGray(UInt8(gray)))
            adjusted[gray] = value
            // 与 ToneProfile.levelIndex 的表达式逐字对应：value / 255 * (levels - 1)
            normalized[gray] = value / 255.0 * Double(ToneProfile.fourLevels - 1)
        }
    }

    deinit {
        palette.deallocate()
        adjusted.deallocate()
        normalized.deallocate()
    }

    /// 判定分支。块循环按模式在**循环外**分派，循环内不再做分支。
    enum Mode {
        case legacyBinary
        case twoLevel
        case fourLevelFlat
        case fourLevelDithered
    }

    var mode: Mode {
        if usesFourLevels {
            return fourLevelFlat ? .fourLevelFlat : .fourLevelDithered
        }
        return isLegacyBinary ? .legacyBinary : .twoLevel
    }

    @inline(__always) var paletteBase: UnsafePointer<UInt8> { UnsafePointer(palette) }
    @inline(__always) var adjustedBase: UnsafePointer<Double> { UnsafePointer(adjusted) }
    @inline(__always) var normalizedBase: UnsafePointer<Double> { UnsafePointer(normalized) }

    /// 源灰度 + 逻辑字节序号 → 调色板字节。与 `CdToneMapping.map` 逐字节一致。
    @inline(__always)
    func byte(gray: UInt8, sampleIndex: Int64) -> UInt8 {
        let grayIndex = Int(gray)
        if usesFourLevels {
            if fourLevelFlat {
                return palette[grayIndex >> 6]
            }
            let phase = cdDitherPhase(sampleIndex)
            let dithered = normalized[grayIndex] + strength * (phase - 0.5)
            let index = Int(dithered.rounded(.toNearestOrAwayFromZero))
            return palette[min(max(index, 0), ToneProfile.fourLevels - 1)]
        }

        if isLegacyBinary {
            return Double(gray) >= 128 ? palette[1] : palette[0]
        }
        let phase = cdDitherPhase(sampleIndex)
        let shifted = 128 + strength * 255.0 * (phase - 0.5)
        return adjusted[grayIndex] >= shifted ? palette[1] : palette[0]
    }
}

/// 并行绘制用：一次算出一整块原始音频字节。
///
/// 采样（`CdImageSampler`）只依赖逻辑字节序号，块与块之间没有状态，
/// 所以可以整块并行；交织依赖全局字节顺序，由调用方按序消费。
struct CdBlockSampler: Sendable {
    let sampler: CdImageSampler
    let tone: CdToneLUT

    init(sampler: CdImageSampler, tone: ToneProfile) {
        self.sampler = sampler
        self.tone = CdToneLUT(tone: tone)
    }

    /// 把 `[start, start+count)` 这段逻辑字节的调色板值写进 `output`。
    ///
    /// 判定模式在循环**外**分派一次，循环里只剩「采样 → 查表 → 判定」，
    /// 所有常量都提前取到局部变量：这样每个字节约 11 ns（采样约 10 ns、
    /// 影调约 1 ns），比逐字节走 `CdToneMapping.map` 快一倍多。
    func fill(start: Int, count: Int, into output: UnsafeMutablePointer<UInt8>) {
        guard count > 0 else { return }
        let palette = tone.paletteBase
        let strength = tone.strength
        var offset = 0
        var byteIndex = start

        switch tone.mode {
        case .legacyBinary:
            let black = palette[0]
            let white = palette[1]
            while offset < count {
                let gray = sampler.gray(atByte: byteIndex)
                output[offset] = Double(gray) >= 128 ? white : black
                offset += 1
                byteIndex += 1
            }

        case .twoLevel:
            let black = palette[0]
            let white = palette[1]
            let adjusted = tone.adjustedBase
            while offset < count {
                let gray = sampler.gray(atByte: byteIndex)
                let shifted = 128 + strength * 255.0 * (cdDitherPhase(Int64(byteIndex)) - 0.5)
                output[offset] = adjusted[Int(gray)] >= shifted ? white : black
                offset += 1
                byteIndex += 1
            }

        case .fourLevelFlat:
            while offset < count {
                let gray = sampler.gray(atByte: byteIndex)
                output[offset] = palette[Int(gray) >> 6]
                offset += 1
                byteIndex += 1
            }

        case .fourLevelDithered:
            let normalized = tone.normalizedBase
            while offset < count {
                let gray = sampler.gray(atByte: byteIndex)
                let dithered = normalized[Int(gray)] + strength * (cdDitherPhase(Int64(byteIndex)) - 0.5)
                let index = Int(dithered.rounded(.toNearestOrAwayFromZero))
                output[offset] = palette[min(max(index, 0), ToneProfile.fourLevels - 1)]
                offset += 1
                byteIndex += 1
            }
        }
    }
}
