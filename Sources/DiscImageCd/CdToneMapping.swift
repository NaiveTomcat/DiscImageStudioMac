import DiscImageCore
import Foundation

/// CD 的灰阶调色板：把 `ToneProfile` 的判定结果翻译成音频样本字节。
///
/// 源项目 `CdToneMapping.cs` 的两套调色板（与 `docs/CD_AUDIO_COMPATIBILITY.md` 一致）：
///
/// - 2 阶：`0x0D`（黑）/ `0xAA`（白）
/// - 4 阶：`0x0D` / `0x10` / `0x63` / `0xAA`
///
/// 判定一律交给 `DiscImageCore.ToneProfile`（`useWhite` / `levelIndex`），
/// **样本索引必须是逻辑字节序号**（`globalByte`），不是文件位置、也不是屏幕坐标：
/// 延迟交织会把字节在文件里挪位，读回预览仍按同一个逻辑序号还原，生成与读回
/// 才能逐字节对上。
///
/// 4 阶调色板里 `0x21` / `0x28` 是参考实现 cdimage 的中间图案，本项目的
/// `0x10` / `0x63` 与源项目现行版本一致（见 `CdToneMapping.DisplayGray` 的映射）。
public enum CdToneMapping {
    /// 调色板里的黑（显示灰 0）。
    public static let blackPaletteByte: UInt8 = 0x0D
    /// 调色板里的白（显示灰 255）。
    public static let whitePaletteByte: UInt8 = 0xAA

    /// 2 阶调色板，由暗到亮。
    public static let twoLevelPalette: [UInt8] = [blackPaletteByte, whitePaletteByte]
    /// 4 阶调色板，由暗到亮。
    public static let fourLevelPalette: [UInt8] = [0x0D, 0x10, 0x63, whitePaletteByte]

    /// 取指定阶数的调色板。阶数不是 4 时一律按 2 阶处理（与 `ToneProfile` 语义一致）。
    public static func palette(levels: Int) -> [UInt8] {
        levels == ToneProfile.fourLevels ? fourLevelPalette : twoLevelPalette
    }

    /// 源灰度 → 调色板字节。
    ///
    /// - Parameters:
    ///   - gray: 源图灰度（0…255）
    ///   - tone: 影调（调用方负责 `normalized()`，这里不再校验）
    ///   - sampleIndex: **逻辑**字节序号（`globalByte`）
    public static func map(gray: UInt8, tone: ToneProfile, sampleIndex: Int64) -> UInt8 {
        let palette = palette(levels: tone.levels)
        // ToneProfile.levelIndex 在 2 阶时返回 0/1、4 阶时返回 0…3，正好是调色板下标。
        let index = tone.levelIndex(gray, sampleIndex: sampleIndex)
        return palette[min(max(index, 0), palette.count - 1)]
    }

    /// 调色板字节 → 显示灰，供读回预览按同一套档位渲染。
    public static func displayGray(paletteByte: UInt8) -> UInt8 {
        switch paletteByte {
        case 0x0D: return 0
        case 0x10: return 85
        case 0x21: return 96
        case 0x28: return 160
        case 0x63: return 170
        case 0xAA: return 255
        default: return paletteByte
        }
    }

    /// 某个字节是否落在调色板里（测试与读回预览自检用）。
    public static func isPaletteByte(_ value: UInt8, levels: Int) -> Bool {
        palette(levels: levels).contains(value)
    }
}
