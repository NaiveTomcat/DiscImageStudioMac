import DiscImageCore
import Foundation

/// DVD 引擎的公开入口（CLI / UI 都通过 `DiscImageGenerator` 协议调用它）。
///
/// 两条路径：
/// - **纯绘图**（`dataDirectory == nil`）：写一个最小 ISO9660 卷（LBA 16 起），
///   元数据之后整盘都是图片纹理；这样输出既能被 `hdiutil attach` 挂载，
///   又能让刻录后的盘面显示图案。
/// - **数据盘**（给了文件夹）：用 `Iso9660Writer` 写文件系统与文件，文件默认贴内圈
///   （`dataAtOuterRing == false`）或贴外圈；剩下的连续区间画图。
///
/// 每个 16 扇区的 ECC Block 都是「先采样出 payload，再顺序写 sink」，
/// 中途检查取消令牌并回调进度；不做 beam search 求解（首版不移植，见 HANDOFF §6.A）。
public struct DvdImageGenerator: DiscImageGenerator {
    /// 标准初始调制边界：状态 1、DSV 0、land。
    private static let initialBoundary = DvdModulationBoundary.standard

    public init() {}

    public var family: DiscFamily { .dvd }

    public func generate(
        _ request: GenerationRequest,
        to sink: SequentialSink,
        progress: @Sendable (DiscProgress) -> Void
    ) throws -> GenerationResult {
        let geometry = request.geometry
        guard geometry.family == .dvd else {
            throw DiscError.invalidGeometry("DvdImageGenerator 只接受 DVD 几何（当前 \(geometry.family.displayNameZH)）")
        }
        try geometry.validate()
        guard request.outputFormat == .iso else {
            throw DiscError.unsupported("DVD 只支持 ISO 映像输出（当前 \(request.outputFormat.displayNameZH)）")
        }
        let tone = request.tone.normalized()
        guard tone.isDvdCompatible else {
            throw DiscError.unsupported("DVD 只有两阶纹理，影调 levels 必须为 2（当前 \(request.tone.levels)）")
        }
        let sectors = geometry.sectors
        let totalBytes = Int64(sectors) * Int64(Iso9660Writer.logicalSectorBytes)
        var lastReportedFraction = -Double.infinity
        // 本地节流器：每 1% 回调一次，避免 UI 被每个 Block 淹没。
        func emit(_ stage: String, _ message: String, _ fraction: Double) {
            let clamped = min(max(fraction, 0), 1)
            if clamped >= 1 || clamped - lastReportedFraction >= 0.01 {
                lastReportedFraction = clamped
                progress(DiscProgress(stage: stage, message: message, fraction: clamped))
            }
        }
        let painter = try DvdPayloadPainter(
            geometry: geometry,
            image: request.image,
            tone: tone,
            clockwise: request.clockwise
        )

        if let dataDirectory = request.dataDirectory {
            return try generateDataDisc(
                request,
                dataDirectory: dataDirectory,
                painter: painter,
                sink: sink,
                emit: emit,
                totalBytes: totalBytes
            )
        }
        return try generateDrawing(
            request,
            painter: painter,
            sink: sink,
            emit: emit,
            totalBytes: totalBytes
        )
    }

    // MARK: - 纯绘图

    private func generateDrawing(
        _ request: GenerationRequest,
        painter: DvdPayloadPainter,
        sink: SequentialSink,
        emit: (String, String, Double) -> Void,
        totalBytes: Int64
    ) throws -> GenerationResult {
        let sectors = request.geometry.sectors
        var plan: Iso9660LayoutPlan?
        var drawingStart = 0
        if let candidate = try? Iso9660Writer.plan(
            entries: [],
            volumeSectors: sectors,
            volumeLabel: request.volumeLabel
        ) {
            let start = Self.alignToBlock(candidate.metadataEndLbaExclusive)
            if sectors - start >= DvdConstants.sectorsPerBlock {
                plan = candidate
                drawingStart = start
            }
        }

        if let plan {
            emit("filesystem", "写入 ISO9660 / Joliet 元数据…", 0.01)
            try request.cancellation.check()
            try Iso9660Writer.writeMetadata(plan, to: sink)
        } else {
            emit("mapping", "几何太小，容不下 ISO9660 元数据：输出纯 payload 映像（不可挂载）", 0.01)
        }

        try sink.pad(to: Int64(drawingStart) * Int64(Iso9660Writer.logicalSectorBytes), with: 0)
        try paintBlocks(
            startLba: drawingStart,
            endLba: sectors,
            painter: painter,
            request: request,
            sink: sink,
            emit: emit,
            baseFraction: 0.02,
            fractionSpan: 0.97
        )
        try sink.pad(to: totalBytes, with: 0)

        let summary = plan == nil
            ? "DVD 纯绘图：\(sectors) 扇区（\(sectors / DvdConstants.sectorsPerBlock) 个 ECC Block），无文件系统"
            : "DVD 纯绘图：\(sectors) 扇区，绘图区 LBA \(drawingStart)…\(sectors - 1)"
        emit("finalize", "完成", 1)
        return GenerationResult(byteCount: totalBytes, summary: summary)
    }

    // MARK: - 数据盘

    private func generateDataDisc(
        _ request: GenerationRequest,
        dataDirectory: URL,
        painter: DvdPayloadPainter,
        sink: SequentialSink,
        emit: (String, String, Double) -> Void,
        totalBytes: Int64
    ) throws -> GenerationResult {
        let sectors = request.geometry.sectors
        let entries = try FileTree.scan(root: dataDirectory)
        let plan = try Iso9660Writer.plan(
            entries: entries,
            volumeSectors: sectors,
            volumeLabel: request.volumeLabel,
            filesAtOuterRing: request.dataAtOuterRing
        )
        let range = try drawingRange(plan: plan, sectors: sectors)

        emit(
            "filesystem",
            "写入 ISO9660 / Joliet 元数据（\(plan.directoryCount) 个目录、\(plan.fileCount) 个文件）…",
            0.01
        )
        try request.cancellation.check()
        try Iso9660Writer.writeMetadata(plan, to: sink)

        if !plan.filesAtOuterRing {
            emit("filesystem", "写入文件数据 \(plan.fileBytes) 字节…", 0.02)
            try request.cancellation.check()
            try Iso9660Writer.writeFileData(plan, to: sink, padToVolumeEnd: false)
        }

        try sink.pad(to: Int64(range.startLba) * Int64(Iso9660Writer.logicalSectorBytes), with: 0)
        try paintBlocks(
            startLba: range.startLba,
            endLba: range.endLba,
            painter: painter,
            request: request,
            sink: sink,
            emit: emit,
            baseFraction: 0.05,
            fractionSpan: 0.9
        )

        if plan.filesAtOuterRing {
            emit("filesystem", "写入外圈文件数据 \(plan.fileBytes) 字节…", 0.96)
            try request.cancellation.check()
            try Iso9660Writer.writeFileData(plan, to: sink, padToVolumeEnd: false)
        }
        try sink.pad(to: totalBytes, with: 0)

        let placement = plan.filesAtOuterRing ? "外圈" : "内圈"
        let summary = "DVD 数据盘：\(sectors) 扇区，文件 \(plan.fileCount) 个 / "
            + "\(plan.fileBytes) 字节（\(placement)），绘图区 LBA \(range.startLba)…\(range.endLba - 1)"
        emit("finalize", "完成", 1)
        return GenerationResult(byteCount: totalBytes, summary: summary)
    }

    // MARK: - 绘图区与逐块写入

    private struct DrawingRange {
        let startLba: Int
        let endLba: Int
    }

    private func drawingRange(plan: Iso9660LayoutPlan, sectors: Int) throws -> DrawingRange {
        let start: Int
        let end: Int
        if plan.filesAtOuterRing {
            start = Self.alignToBlock(plan.metadataEndLbaExclusive)
            end = (plan.fileDataStartLba / DvdConstants.sectorsPerBlock) * DvdConstants.sectorsPerBlock
        } else {
            start = Self.alignToBlock(plan.dataEndLbaExclusive)
            end = sectors
        }
        guard end - start >= DvdConstants.sectorsPerBlock else {
            throw DiscError.unsupported(
                "文件系统没有给绘图区留下完整的 ECC Block（绘图区 LBA \(start)…\(end)，卷共 \(sectors) 扇区）"
            )
        }
        return DrawingRange(startLba: start, endLba: end)
    }

    /// 逐块绘制并按 LBA 顺序写入 `SequentialSink`。
    ///
    /// 每个 ECC Block 都是一次「先采样、再顺序写」，中途检查取消令牌并回调进度。
    /// 备注（第二轮优化方向）：源项目用「并行生成 + 按序写出」提速；本次实现
    /// 先保证链路正确，单线程顺序写，避免在共享构建机上与其他进程抢核心。
    private func paintBlocks(
        startLba: Int,
        endLba: Int,
        painter: DvdPayloadPainter,
        request: GenerationRequest,
        sink: SequentialSink,
        emit: (String, String, Double) -> Void,
        baseFraction: Double,
        fractionSpan: Double
    ) throws {
        let totalBlocks = (endLba - startLba) / DvdConstants.sectorsPerBlock
        guard totalBlocks > 0 else { return }
        var payloads = [UInt8](repeating: 0, count: DvdConstants.payloadBytesPerBlock)
        for blockIndex in 0..<totalBlocks {
            try request.cancellation.check()
            let lba = startLba + blockIndex * DvdConstants.sectorsPerBlock
            painter.paintBlock(firstLba: lba, payloads: &payloads)
            try sink.write(payloads)
            let fraction = baseFraction + fractionSpan * Double(blockIndex + 1) / Double(totalBlocks)
            emit("mapping", "绘制 ECC Block \(blockIndex + 1)/\(totalBlocks)（LBA \(lba)）", fraction)
        }
    }

    private static func alignToBlock(_ lba: Int) -> Int {
        let block = DvdConstants.sectorsPerBlock
        let remainder = lba % block
        return remainder == 0 ? lba : lba + (block - remainder)
    }
}
