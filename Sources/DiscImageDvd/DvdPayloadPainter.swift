import DiscImageCore
import Foundation

/// 快速纹理映射：图片 → 每个 payload 字节的扰码域取值 Q（0xA5 / 0x92）。
///
/// 链路（HANDOFF §2.1）：
/// ```
/// 图片 → 按 619008 通道位坐标系采样 → 每个 payload 码字取 land 数目标
///      → Q 只在 0xA5（黑，5 次 transition）/ 0x92（白，2 次）里选
///      → P = Q XOR 扰码掩码
/// ```
/// 这里只做「选 Q 并扰码」；ECC / EFMPlus / NRZI 由 `DvdChannelEncoder` 负责，
/// 因为光盘刻录时 ECC 是刻录机固件按 payload 重建的（与源项目一致）。
///
/// 性能要点（输出与优化前逐字节一致）：
/// - 每个 ECC Block 只在第一个 payload 码字上做一次精确的弧长 →（半径，角度）求解，
///   之后按已知的通道位偏移做局部线性推进（`DvdSpiral.advance`）+ 二阶旋转递推；
///   每个 Block 精确重开，误差不跨块累积；
/// - 整个 Block 在 `payloads` / 通道位偏移表 / 图片像素的 `UnsafeBufferPointer`
///   里跑完（省掉每字节的数组边界检查与跨模块属性访问）；
/// - 影调判定走 `DvdToneDecider`（预计算 256 项灰度表 + 内联抖动哈希）。
struct DvdPayloadPainter: Sendable {
    let spiral: DvdSpiral
    let sampler: DvdDiscSampler
    let decider: DvdToneDecider
    /// DVD 的螺旋方向是顺时针（源项目约定）。
    let clockwise: Bool
    let startAngleRadians: Double

    /// 32768 个 payload 字节的码字中心，相对 Block 起始的通道位偏移。
    static let channelOffsets: [Int] = (0..<DvdConstants.payloadBytesPerBlock).map {
        DvdEccBlockBuilder.payloadDirectChannelOffset($0) + 8
    }

    init(
        geometry: DiscGeometry,
        image: RasterImage,
        tone: ToneProfile,
        clockwise: Bool,
        startAngleRadians: Double = 0
    ) throws {
        let spiral = try DvdSpiral(geometry: geometry)
        self.init(
            spiral: spiral,
            image: image,
            tone: tone,
            clockwise: clockwise,
            startAngleRadians: startAngleRadians
        )
    }

    init(
        spiral: DvdSpiral,
        image: RasterImage,
        tone: ToneProfile,
        clockwise: Bool,
        startAngleRadians: Double = 0
    ) {
        self.spiral = spiral
        sampler = DvdDiscSampler(image: image, outerRadiusMm: spiral.outerRadiusMm)
        decider = DvdToneDecider(tone: tone)
        self.clockwise = clockwise
        self.startAngleRadians = startAngleRadians
    }

    /// 给一个 16 扇区 Block 生成 payload。
    ///
    /// - `payloads` 长度必须是 32768；函数会先清零。
    /// - 图片外（alpha = 0）的字节保持 0，属于「不受控区」，刻录后是扰码噪声。
    func paintBlock(firstLba: Int, payloads: inout [UInt8]) {
        precondition(payloads.count == DvdConstants.payloadBytesPerBlock)
        payloads.withUnsafeMutableBufferPointer { output in
            paintBlock(firstLba: firstLba, payloads: output)
        }
    }

    /// `paintBlock` 的缓冲指针版本（并行管线一次画多个 Block 时用，避免复制）。
    func paintBlock(firstLba: Int, payloads output: UnsafeMutableBufferPointer<UInt8>) {
        precondition(output.count == DvdConstants.payloadBytesPerBlock)
        precondition(firstLba >= 0 && firstLba % DvdConstants.sectorsPerBlock == 0)
        output.update(repeating: 0)

        let blockFirstGlobalBit = Double(firstLba) * Double(DvdConstants.channelBitsPerSector)
        let direction = clockwise ? -1.0 : 1.0
        let bitLength = spiral.channelBitLengthMm
        let offsets = Self.channelOffsets

        offsets.withUnsafeBufferPointer { channelOffsets in
            sampler.withUnsafePixels { pixels in
                var radiusMm = 0.0
                var cosTheta = 1.0
                var sinTheta = 0.0
                var previousGlobalBit = 0.0

                for sector in 0..<DvdConstants.sectorsPerBlock {
                    let psn = UInt32(firstLba + sector) &+ DvdConstants.physicalSectorNumberOffset
                    let mask = DvdDataFrameBuilder.payloadScramblerMask(physicalSectorNumber: psn)
                    let toneBase = Int64(firstLba + sector) * Int64(DvdConstants.payloadBytesPerSector)
                    let payloadBase = sector * DvdConstants.payloadBytesPerSector
                    for byteIndex in 0..<DvdConstants.payloadBytesPerSector {
                        let payloadIndex = payloadBase + byteIndex
                        let globalBit = blockFirstGlobalBit + Double(channelOffsets[payloadIndex])
                        if payloadIndex == 0 {
                            // 每个 Block 精确重开，清掉上一批的递推误差。
                            let point = spiral.atArcLength(globalBit * bitLength)
                            radiusMm = point.radiusMm
                            let angle = startAngleRadians + direction * point.angleRadians
                            cosTheta = cos(angle)
                            sinTheta = sin(angle)
                        } else {
                            let deltaArc = (globalBit - previousGlobalBit) * bitLength
                            let step = spiral.advance(radiusMm: radiusMm, deltaArcLengthMm: deltaArc)
                            radiusMm = step.radiusMm
                            let deltaAngle = direction * step.deltaAngleRadians
                            let halfSquare = 0.5 * deltaAngle * deltaAngle
                            let nextCos = cosTheta * (1 - halfSquare) - sinTheta * deltaAngle
                            let nextSin = sinTheta * (1 - halfSquare) + cosTheta * deltaAngle
                            cosTheta = nextCos
                            sinTheta = nextSin
                        }
                        previousGlobalBit = globalBit

                        let sample = sampler.sample(
                            xMm: radiusMm * cosTheta,
                            yMm: radiusMm * sinTheta,
                            pixels: pixels
                        )
                        guard sample.alpha > 0 else { continue }
                        let white = decider.useWhite(
                            sample.luminance,
                            sampleIndex: toneBase + Int64(byteIndex)
                        )
                        let scrambled: UInt8 = white
                            ? DvdConstants.whiteScrambledByte
                            : DvdConstants.blackScrambledByte
                        output[payloadIndex] = scrambled ^ mask[byteIndex]
                    }
                }
            }
        }
    }
}
