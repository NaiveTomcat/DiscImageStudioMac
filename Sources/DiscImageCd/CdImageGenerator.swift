import DiscImageCore
import DiscImageDvd
import Foundation

/// CD 引擎的公开入口（工作包 B）。
///
/// 按 `GenerationRequest.outputFormat` 分派：
///
/// | 输出 | 内容 |
/// |---|---|
/// | `.wav` | 44 字节 RIFF 头 + 小端 PCM 音轨，并在 `outputBaseURL` 旁写同名 `.cue` |
/// | `.raw` | 大端裸扇区流（`cdrecord -audio` 的默认约定），不写 CUE |
/// | `.iso` | 数据盘模式：CD-ROM Mode 1 + ISO9660（见下方 TODO） |
///
/// 三种输出都走 `SequentialSink` 前向写（刻录流不可 Seek）。
/// 音轨长度恒为 `sectors × 2352`；WAV 文件再长 44 字节的头。
public struct CdImageGenerator: DiscImageGenerator {
    public var family: DiscFamily { .cd }

    public init() {}

    public func generate(
        _ request: GenerationRequest,
        to sink: SequentialSink,
        progress: @Sendable (DiscProgress) -> Void
    ) throws -> GenerationResult {
        guard request.geometry.family == .cd else {
            throw DiscError.unsupported("CdImageGenerator 只处理 CD 几何（收到 \(request.geometry.family.displayNameZH)）")
        }
        try request.geometry.validate()
        let parameters = CdDiscParameters(geometry: request.geometry)
        try parameters.validate()
        let tone = request.tone.normalized()
        let throttle = CdProgressThrottle(minimumStep: 0.01)

        throttle.emit(
            stage: "geometry",
            message: "CD 几何：\(parameters.sectors) 扇区，"
                + String(format: "%.3f–%.3f mm", parameters.innerRadiusMm, parameters.outerRadiusMm),
            fraction: 0,
            to: progress
        )

        switch request.outputFormat {
        case .wav:
            return try generateWave(request, parameters: parameters, tone: tone, to: sink, throttle: throttle, progress: progress)
        case .raw:
            return try generateRaw(request, parameters: parameters, tone: tone, to: sink, throttle: throttle, progress: progress)
        case .iso:
            return try generateDataImage(
                request,
                parameters: parameters,
                tone: tone,
                to: sink,
                throttle: throttle,
                progress: progress
            )
        }
    }

    // MARK: - CD-DA：WAV + CUE

    private func generateWave(
        _ request: GenerationRequest,
        parameters: CdDiscParameters,
        tone: ToneProfile,
        to sink: SequentialSink,
        throttle: CdProgressThrottle,
        progress: (DiscProgress) -> Void
    ) throws -> GenerationResult {
        let audioBytes = parameters.totalBytes
        try sink.write(try CdWaveFile.header(audioBytes: audioBytes))

        let written = try CdAudioTrackGenerator.writeTrack(
            image: request.image,
            parameters: parameters,
            tone: tone,
            byteOrder: .littleEndian,
            to: sink,
            progress: progress,
            cancellation: request.cancellation
        )

        var sidecars: [URL] = []
        if let base = request.outputBaseURL {
            sidecars.append(try CdWaveFile.writeCue(besideBaseURL: base))
            throttle.emit(stage: "finalize", message: "已写出同名 CUE 文件", fraction: 1, to: progress)
        }

        return GenerationResult(
            byteCount: sink.position,
            summary: "CD-DA 音轨（WAV 小端 PCM + CUE）：\(parameters.sectors) 扇区，"
                + "\(written) 字节音频，\(String(format: "%.1f", parameters.totalTimeSeconds / 60)) 分钟",
            sidecarURLs: sidecars
        )
    }

    // MARK: - CD-DA：RAW（大端）

    private func generateRaw(
        _ request: GenerationRequest,
        parameters: CdDiscParameters,
        tone: ToneProfile,
        to sink: SequentialSink,
        throttle: CdProgressThrottle,
        progress: (DiscProgress) -> Void
    ) throws -> GenerationResult {
        let written = try CdAudioTrackGenerator.writeTrack(
            image: request.image,
            parameters: parameters,
            tone: tone,
            byteOrder: .bigEndian,
            to: sink,
            progress: progress,
            cancellation: request.cancellation
        )

        return GenerationResult(
            byteCount: sink.position,
            summary: "CD-DA 音轨（RAW 大端扇区流，cdrecord -audio 约定不加 -swab）："
                + "\(parameters.sectors) 扇区，\(written) 字节",
            sidecarURLs: []
        )
    }

    // MARK: - 数据盘（Mode 1 + ISO9660）

    /// CD 数据盘模式。
    ///
    /// 输出的是**cooked**映像：每个逻辑扇区 2048 字节（扇区数 × 2048 = 文件长度），
    /// 同步头、EDC/ECC、扰码与 CIRC 都由刻录后端（驱动器固件 / IMAPI）补齐。
    ///
    /// 布局来自工作包 A 的 `Iso9660Writer.plan`（文件在内圈还是外圈、绘图区是哪段 LBA）。
    /// 文件系统字节原样写出；**绘图区**的每个 payload 走 `CdDataPayload`：
    /// 按扰码 + 相邻字节交换反查采样位置，再 XOR 上 ECMA-130 扰码掩码。这样刻成盘、
    /// 光驱做过扰码与字节交换之后，图案才落在正确位置。
    ///
    /// 文件在内圈时：元数据 → 文件 → 绘图区（到卷尾）；
    /// 文件在外圈时：元数据 → 绘图区 → 文件（到卷尾）。
    private func generateDataImage(
        _ request: GenerationRequest,
        parameters: CdDiscParameters,
        tone: ToneProfile,
        to sink: SequentialSink,
        throttle: CdProgressThrottle,
        progress: (DiscProgress) -> Void
    ) throws -> GenerationResult {
        guard let directory = request.dataDirectory else {
            throw DiscError.missingPayload("CD 数据盘模式需要先选择要写入光盘的文件夹（dataDirectory 为空）")
        }

        try request.cancellation.check()
        let entries = try FileTree.scan(root: directory)
        let plan = try Iso9660Writer.plan(
            entries: entries,
            volumeSectors: parameters.sectors,
            volumeLabel: request.volumeLabel,
            filesAtOuterRing: request.dataAtOuterRing
        )

        // 源项目的绘图区定义：内圈布局在文件之后，外圈布局夹在元数据与文件之间。
        let drawingStart = plan.filesAtOuterRing ? plan.metadataEndLbaExclusive : plan.dataEndLbaExclusive
        let drawingEnd = plan.filesAtOuterRing ? plan.fileDataStartLba : plan.volumeSectors
        guard drawingStart < drawingEnd else {
            throw DiscError.invalidGeometry(
                "数据文件夹占满了整张盘，没有留下绘图区（\(plan.fileCount) 个文件、"
                    + "\(plan.directoryCount) 个目录，绘图区 \(drawingStart)…\(drawingEnd)）"
            )
        }

        let sectorBytes = Iso9660Writer.logicalSectorBytes
        let sampler = CdImageSampler(image: request.image, parameters: parameters)

        throttle.emit(
            stage: "filesystem",
            message: "写入 ISO9660 文件系统（\(plan.fileCount) 个文件，"
                + "文件区\(plan.filesAtOuterRing ? "外圈" : "内圈")）",
            fraction: 0,
            to: progress
        )
        try Iso9660Writer.writeMetadata(plan, to: sink)
        if !plan.filesAtOuterRing {
            try Iso9660Writer.writeFileData(plan, to: sink, padToVolumeEnd: false)
        }

        // 绘图区：逐扇区写 2048 字节 payload（已采样、已调色、已扰码补偿）。
        try sink.pad(to: Int64(drawingStart) * Int64(sectorBytes), with: 0)
        let drawingSectors = drawingEnd - drawingStart
        for index in 0..<drawingSectors {
            if index & 0xFF == 0 {
                try request.cancellation.check()
            }
            let lba = drawingStart + index
            try sink.write(CdDataPayload.drawingPayload(lba: lba, sampler: sampler, tone: tone))

            let fraction = Double(index + 1) / Double(drawingSectors)
            throttle.emit(
                stage: "mapping",
                message: String(
                    format: "绘制数据盘绘图区（%d/%d 扇区，%.1f%%）",
                    index + 1,
                    drawingSectors,
                    fraction * 100
                ),
                fraction: fraction,
                to: progress
            )
        }
        try sink.pad(to: Int64(drawingEnd) * Int64(sectorBytes), with: 0)

        if plan.filesAtOuterRing {
            throttle.emit(stage: "filesystem", message: "写入外圈文件数据", fraction: 1, to: progress)
            try Iso9660Writer.writeFileData(plan, to: sink, padToVolumeEnd: true)
        } else {
            try sink.pad(to: Int64(plan.volumeSectors) * Int64(sectorBytes), with: 0)
        }

        return GenerationResult(
            byteCount: sink.position,
            summary: "CD 数据盘（ISO9660 Mode 1 cooked 映像）：\(plan.volumeSectors) 扇区 × 2048 字节，"
                + "\(plan.fileCount) 个文件（\(plan.fileBytes) 字节），"
                + "绘图区 LBA \(drawingStart)…\(drawingEnd)",
            sidecarURLs: []
        )
    }
}
