import Foundation
import DiscImageCore

/// 蓝光 BD-R 图像引擎。
///
/// 对外唯一入口（名字由 HANDOFF §6.C / task-3 固定）：
/// ```
/// public struct BluRayImageGenerator: DiscImageGenerator
/// ```
///
/// 生成链路：
/// 1. 规划 —— 有数据目录时建立 UDF 2.01 分区（内圈或外圈），否则整盘纯绘图；
/// 2. 二值化 —— `ToneProfile` 在源图分辨率一次性决定明暗；
/// 3. 取样 —— 每个 payload 字节按 LDC 交织后的名义物理位置取源图像素；
/// 4. 定灰 —— 暗 `0xAA`（偏 3T）/ 亮 `0x44`（偏 6T），可反转；
/// 5. 加扰 —— 簇内 32 个扇区共用同一 PSN 掩码（抵消驱动器的标准加扰）；
/// 6. 文件系统 —— UDF 2.01 前缀 / 后缀，输出长度必须是 `扇区数 × 2048`。
///
/// 输出是**普通 2048 字节扇区镜像**：驱动器再计算 EDC、LDC/BIS 校验并做 17PP/NRZI。
/// 本机没有刻录机，因此只验证到「镜像结构正确、UDF 可挂载」，不实测盘面亮度与极性。
public struct BluRayImageGenerator: DiscImageGenerator {
    public init() {}

    public var family: DiscFamily { .bluRay }

    public func generate(
        _ request: GenerationRequest,
        to sink: SequentialSink,
        progress: @Sendable (DiscProgress) -> Void
    ) throws -> GenerationResult {
        // 32 × 2052 = 304 × 216 与 962,136 通道位的显式断言。
        BluRaySpec.validateLayout()

        guard request.geometry.family == .bluRay else {
            throw DiscError.invalidGeometry("BluRayImageGenerator 只接受蓝光几何（当前 \(request.geometry.family.displayNameZH)）")
        }
        try request.geometry.validate()
        guard request.outputFormat == .iso else {
            throw DiscError.unsupported("蓝光只支持 ISO 输出（当前 \(request.outputFormat.displayNameZH)）")
        }
        guard request.tone.levels == ToneProfile.twoLevels else {
            throw DiscError.unsupported("蓝光影调只支持两阶（当前 \(request.tone.levels) 阶）")
        }
        try request.tone.validate()
        let tone = request.tone.normalized()

        let totalSectors = request.geometry.sectors
        let totalBytes = Int64(totalSectors) * Int64(BluRaySpec.bytesPerSector)
        let geometry = try BluRayTrackGeometry(
            innerRadiusMm: request.geometry.innerRadiusMm,
            outerRadiusMm: request.geometry.outerRadiusMm,
            totalSectors: totalSectors
        )

        // 进度节流：协议里的 `progress` 是非逃逸闭包，不能交给 ProgressThrottle 保存。
        var lastFraction = -Double.infinity
        func emit(_ stage: String, _ message: String, _ fraction: Double) {
            if fraction >= 1.0 || fraction - lastFraction >= 0.01 {
                lastFraction = fraction
                progress(DiscProgress(stage: stage, message: message, fraction: min(max(fraction, 0), 1)))
            }
        }
        emit("geometry", "规划蓝光盘片几何（\(totalSectors) 扇区）", 0)

        // MARK: 规划文件系统与绘图范围

        let udfPlan: UDFImageWriter.LayoutPlan?
        let drawingStart: UInt32
        let drawingEnd: UInt32
        let volumeLabel: String
        let udfTimestamp: Date?

        if let dataDirectory = request.dataDirectory {
            let plan = try UDFImageWriter.plan(
                sourceDirectory: dataDirectory,
                volumeSectors: UInt32(totalSectors),
                volumeLabel: request.volumeLabel,
                timestamp: nil,
                filesAtOuterRing: request.dataAtOuterRing
            )
            guard plan.drawingStartLBA < plan.drawingEndLBAExclusive else {
                throw DiscError.invalidGeometry("UDF 文件系统没有给绘图区留下完整簇")
            }
            udfPlan = plan
            drawingStart = plan.drawingStartLBA
            drawingEnd = plan.drawingEndLBAExclusive
            volumeLabel = plan.volumeLabel
            udfTimestamp = plan.timestamp
        } else {
            udfPlan = nil
            drawingStart = 0
            drawingEnd = UInt32(totalSectors)
            volumeLabel = request.volumeLabel.isEmpty ? "BD_IMAGE" : request.volumeLabel
            udfTimestamp = nil
        }

        // 输出（旁写文件）不能落进源数据目录，否则会把自己写进镜像。
        if let base = request.outputBaseURL, let dataDirectory = request.dataDirectory {
            let sidecar = BluRayISOMetadata.sidecarURL(forOutputBase: base).standardizedFileURL.path
            let source = dataDirectory.standardizedFileURL.path
            let prefix = source.hasSuffix("/") ? source : source + "/"
            if sidecar.hasPrefix(prefix) {
                throw DiscError.io("旁写元数据不能写进源数据目录：\(sidecar)")
            }
        }

        // MARK: 二值化

        try request.cancellation.check()
        let mapping = BluRayImagePayloadMapping(
            image: request.image,
            tone: tone,
            geometry: geometry,
            invert: request.geometry.invertMapping
        )
        emit("mapping", "源图二值化并建立 3T/6T 映射", 0.02)

        // MARK: 前缀

        if let plan = udfPlan {
            try request.cancellation.check()
            try UDFImageWriter.writePrefix(plan: plan, to: sink, endLBAExclusive: drawingStart)
            emit(
                "filesystem",
                plan.filesAtOuterRing ? "UDF 2.01 外圈分区已规划" : "UDF 2.01 元数据已写入",
                0.05
            )
        }

        // MARK: 绘图区

        // 每簇是一个完全独立的 64 KiB 输出块：位置只依赖簇号，扰码掩码只依赖簇首 PSN，
        // 没有跨簇携带的编码状态。因此可以放心按簇并行，再由 `ParallelPipeline`
        // 按 0,1,2… 的顺序交给单线程写出 —— 与串行版本逐字节一致。
        let clusterCount = Int((drawingEnd - drawingStart) / UInt32(BluRaySpec.sectorsPerCluster))
        let drawingStartSector = drawingStart
        var completedClusters = 0
        try ParallelPipeline.run(
            count: clusterCount,
            chunkSize: 64,
            workers: ParallelPipeline.defaultWorkers,
            cancellation: request.cancellation,
            produce: { index -> [UInt8] in
                let sector = drawingStartSector + UInt32(index * BluRaySpec.sectorsPerCluster)
                return try mapping.scrambledCluster(firstSector: sector)
            },
            consume: { clusters in
                for clusterBytes in clusters {
                    try sink.write(clusterBytes)
                    completedClusters += 1
                    let fraction = 0.05 + 0.85 * (Double(completedClusters) / Double(max(clusterCount, 1)))
                    emit("mapping", "盘面图案 \(completedClusters)/\(clusterCount) 簇", fraction)
                }
            }
        )

        // MARK: 后缀

        if let plan = udfPlan {
            try request.cancellation.check()
            try UDFImageWriter.writeSuffix(plan: plan, to: sink, startLBA: drawingEnd)
            emit("filesystem", "UDF 2.01 备份元数据已写入", 0.95)
        }

        guard sink.position == totalBytes else {
            throw DiscError.encoding("蓝光镜像长度不正确（\(sink.position) ≠ \(totalBytes)）")
        }
        try request.cancellation.check()

        // MARK: 旁写元数据

        var sidecarURLs: [URL] = []
        if let base = request.outputBaseURL {
            let outputISO = base.pathExtension.isEmpty
                ? base.appendingPathExtension("iso")
                : base
            let startRadius = (try geometry.trackPoint(sectorPosition: Double(drawingStart))).radiusMm
            let endRadius = (try geometry.trackPoint(sectorPosition: Double(drawingEnd))).radiusMm
            let metadata = BluRayISOMetadata(
                outputIso: outputISO.standardizedFileURL.path,
                isoBytes: totalBytes,
                totalSectors: UInt32(totalSectors),
                innerRadiusMm: request.geometry.innerRadiusMm,
                outerRadiusMm: request.geometry.outerRadiusMm,
                invertMapping: request.geometry.invertMapping,
                tone: tone,
                drawingStartSector: drawingStart,
                drawingEndSectorExclusive: drawingEnd,
                drawingStartRadiusMm: startRadius,
                drawingEndRadiusMm: endRadius,
                volumeLabel: volumeLabel,
                dataDirectory: request.dataDirectory?.standardizedFileURL.path,
                udfTimestamp: udfTimestamp,
                generatedUtc: Date(),
                filesAtOuterRing: request.dataAtOuterRing
            )
            let url = BluRayISOMetadata.sidecarURL(forOutputBase: base)
            try metadata.save(to: url)
            sidecarURLs.append(url)
        }

        emit("finalize", "蓝光镜像生成完成", 1)

        let drawingRadiusText = String(
            format: "%.3f–%.3f mm",
            (try geometry.trackPoint(sectorPosition: Double(drawingStart))).radiusMm,
            (try geometry.trackPoint(sectorPosition: Double(drawingEnd))).radiusMm
        )
        let polarity = request.geometry.invertMapping ? "暗 6T / 亮 3T（反转）" : "暗 3T / 亮 6T"
        let filesystem = udfPlan == nil
            ? "纯绘图（无文件系统）"
            : "UDF 2.01（\(udfPlan?.fileCount ?? 0) 个文件，\(request.dataAtOuterRing ? "外圈" : "内圈")）"
        let summary = """
        蓝光 BD-R 镜像：\(totalSectors) 扇区（\(totalBytes) 字节）；\(filesystem)；\
        绘图扇区 \(drawingStart)…\(drawingEnd - 1)（\(drawingRadiusText)）；极性 \(polarity)。
        """
        return GenerationResult(byteCount: totalBytes, summary: summary, sidecarURLs: sidecarURLs)
    }
}
