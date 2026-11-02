import Foundation
import DiscImageCore

/// ECMA-167（第 3 版）/ UDF 2.01（ECMA TR/112-4）只读封闭卷的顺序写入器。
///
/// 物理分区只包含文件系统与文件，可以放在盘首或盘尾；绘图区是分区之外的保留卷空间。
/// 写路径严格前向（不 seek），所以同一个规划既能落盘成 ISO，也能直接喂给顺序刻录流。
///
/// 关键不变式：
/// - 最小 640 扇区且必须是 32 的倍数（给绘图区留出完整簇）；
/// - 单文件按 `0x3ffff800` 字节拆分 64 位 extent（突破 4 GiB）；
/// - 尾部 288 扇区保留给备份卷描述符与锚点。
///
/// 布局依据源项目 `src/DiscImageStudio.Iso/UdfImageWriter.cs`，并按 UDF 2.01 的
/// 字段偏移写入；本机用 `hdiutil attach` 验证可挂载。
public enum UDFImageWriter {
    public static let logicalSectorBytes = 2048
    public static let minimumVolumeSectors: UInt32 = 640
    static let mainVDSLBA: UInt32 = 32
    static let vdsSectors: UInt32 = 16
    static let integrityLBA: UInt32 = 48
    static let firstPartitionLBA: UInt32 = 288
    static let maximumExtentBytes: Int64 = 0x3FFF_F800
    static let implementationID = "*DiscImageStudio"

    // MARK: - 规划

    /// 一个已规划好的 UDF 卷布局。`drawingStart/End` 是留给盘面图案的扇区范围。
    public struct LayoutPlan {
        public let sourceDirectory: URL?
        public let volumeSectors: UInt32
        public let volumeLabel: String
        public let timestamp: Date
        public let fileCount: Int
        public let directoryCount: Int
        public let fileBytes: Int64
        public let dataEndLBAExclusive: UInt32
        public let drawingStartLBA: UInt32
        public let drawingEndLBAExclusive: UInt32
        public let filesAtOuterRing: Bool
        public let partitionStartLBA: UInt32

        public var partitionSectors: UInt32 { dataEndLBAExclusive - partitionStartLBA }
        public var reserveVDSLBA: UInt32 { volumeSectors - 256 }

        /// 规划时扫描出的 UDF 目录树（引用语义，生成期间只读）。
        let nodes: [UDFNode]

        init(
            sourceDirectory: URL?,
            volumeSectors: UInt32,
            volumeLabel: String,
            timestamp: Date,
            fileCount: Int,
            directoryCount: Int,
            fileBytes: Int64,
            dataEndLBAExclusive: UInt32,
            drawingStartLBA: UInt32,
            drawingEndLBAExclusive: UInt32,
            filesAtOuterRing: Bool,
            partitionStartLBA: UInt32,
            nodes: [UDFNode]
        ) {
            self.sourceDirectory = sourceDirectory
            self.volumeSectors = volumeSectors
            self.volumeLabel = volumeLabel
            self.timestamp = timestamp
            self.fileCount = fileCount
            self.directoryCount = directoryCount
            self.fileBytes = fileBytes
            self.dataEndLBAExclusive = dataEndLBAExclusive
            self.drawingStartLBA = drawingStartLBA
            self.drawingEndLBAExclusive = drawingEndLBAExclusive
            self.filesAtOuterRing = filesAtOuterRing
            self.partitionStartLBA = partitionStartLBA
            self.nodes = nodes
        }
    }

    /// 扫描源目录并规划 UDF 2.01 卷。
    ///
    /// - Parameters:
    ///   - sourceDirectory: 要写入的文件目录；nil 表示空卷。
    ///   - volumeSectors: 整卷扇区数（≥640 且 %32 == 0）。
    ///   - filesAtOuterRing: true 时把整个文件系统分区移到盘尾，绘图区留在前面。
    public static func plan(
        sourceDirectory: URL?,
        volumeSectors: UInt32,
        volumeLabel: String,
        timestamp: Date? = nil,
        filesAtOuterRing: Bool = false
    ) throws -> LayoutPlan {
        guard volumeSectors >= minimumVolumeSectors, volumeSectors % UInt32(BluRaySpec.sectorsPerCluster) == 0 else {
            throw DiscError.invalidGeometry(
                "UDF 绘图卷至少需要 \(minimumVolumeSectors) 个扇区且必须是 32 的倍数（当前 \(volumeSectors)）"
            )
        }
        let recorded = timestamp ?? Date()
        let sourcePath = sourceDirectory?.standardizedFileURL

        if let sourcePath {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourcePath.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw DiscError.missingPayload("数据目录不存在：\(sourcePath.lastPathComponent)")
            }
            if try isSymbolicLink(sourcePath) {
                throw DiscError.io("拒绝符号链接：\(sourcePath.lastPathComponent)")
            }
        }

        let root = UDFNode(
            sourcePath: sourcePath?.path ?? "",
            name: "",
            isDirectory: true,
            parent: nil,
            timestamp: sourcePath.map { modificationDate(of: $0) ?? recorded } ?? recorded,
            identifier: [],
            uniqueID: 0,
            dataLength: 0
        )
        var nodes: [UDFNode] = [root]

        // 广度优先遍历源目录（迭代实现，避免深目录递归爆栈）。
        var index = 0
        while index < nodes.count {
            let directory = nodes[index]
            index += 1
            guard directory.isDirectory, !directory.sourcePath.isEmpty else { continue }
            let children = try listDirectory(at: URL(fileURLWithPath: directory.sourcePath))
            for child in children {
                let childNode = UDFNode(
                    sourcePath: child.url.path,
                    name: child.url.lastPathComponent,
                    isDirectory: child.isDirectory,
                    parent: directory,
                    timestamp: child.timestamp,
                    identifier: try encodeIdentifier(child.url.lastPathComponent),
                    uniqueID: UInt64(nodes.count + 15),
                    dataLength: child.isDirectory ? 0 : child.byteCount
                )
                directory.children.append(childNode)
                nodes.append(childNode)
            }
        }

        // 先分配 file entry 扇区，再算目录数据长度（FID 跨扇区规则依赖偏移）。
        var cursor = firstPartitionLBA + 2
        for node in nodes {
            node.entryLBA = cursor
            cursor += 1
            if node.isDirectory {
                node.dataLength = Int64(fileIdentifierLength(identifierBytes: 0, directoryOffset: 0))
                for child in node.children {
                    node.dataLength += Int64(fileIdentifierLength(
                        identifierBytes: child.identifier.count,
                        directoryOffset: Int(node.dataLength)
                    ))
                }
            }
            // 一个 file entry 最多容纳 234 个 short_ad（2048−176 字节 / 8）。
            let extents = (node.dataLength + maximumExtentBytes - 1) / maximumExtentBytes
            guard extents <= Int64((logicalSectorBytes - 176) / 8) else {
                throw DiscError.unsupported("文件需要的分配描述符超过一个 UDF file entry 的容量：\(node.name)")
            }
            guard node.children.filter({ $0.isDirectory }).count < Int(UInt16.max) else {
                throw DiscError.unsupported("子目录数量超过 UDF link count 上限：\(node.name)")
            }
        }

        // 目录数据在前，文件数据在后。
        for node in nodes where node.isDirectory {
            node.dataLBA = cursor
            cursor = cursor &+ sectorCount(node.dataLength)
        }
        for node in nodes where !node.isDirectory {
            node.dataLBA = cursor
            cursor = cursor &+ sectorCount(node.dataLength)
        }

        let drawingEndAligned = ((volumeSectors - 257) / UInt32(BluRaySpec.sectorsPerCluster))
            * UInt32(BluRaySpec.sectorsPerCluster)
        var drawingStart = ((cursor + 31) / 32) * 32
        var drawingEnd = drawingEndAligned
        var partitionStart = firstPartitionLBA

        if filesAtOuterRing {
            // 整个物理分区搬到盘尾：相对地址不变，只改分区起点与绝对写入位置。
            let partitionSectors = cursor - firstPartitionLBA
            guard drawingEndAligned > partitionSectors else {
                throw DiscError.invalidGeometry("数据太多：盘尾放不下文件分区（\(partitionSectors) 扇区）")
            }
            partitionStart = ((drawingEndAligned - partitionSectors) / 32) * 32
            guard partitionStart >= firstPartitionLBA else {
                throw DiscError.invalidGeometry("盘尾文件分区会覆盖卷描述符区（起点 \(partitionStart) < \(firstPartitionLBA)）")
            }
            let shift = partitionStart - firstPartitionLBA
            for node in nodes {
                node.entryLBA = node.entryLBA &+ shift
                node.dataLBA = node.dataLBA &+ shift
            }
            cursor = cursor &+ shift
            drawingStart = firstPartitionLBA
            drawingEnd = partitionStart
        }

        guard drawingStart < drawingEnd else {
            let used = cursor
            throw DiscError.invalidGeometry(
                "文件与 UDF 元数据占用 \(used) 个扇区，尾部备份元数据从 \(drawingEndAligned) 开始；"
                    + "至少需要一个完整的 32 扇区绘图簇"
            )
        }

        let label = fitDstring(volumeLabel.isEmpty ? "BD_IMAGE" : volumeLabel, fieldBytes: 128)
        let fileCount = nodes.filter { !$0.isDirectory }.count
        return LayoutPlan(
            sourceDirectory: sourcePath,
            volumeSectors: volumeSectors,
            volumeLabel: label,
            timestamp: recorded,
            fileCount: fileCount,
            directoryCount: nodes.count - fileCount,
            fileBytes: nodes.filter { !$0.isDirectory }.reduce(0) { $0 + $1.dataLength },
            dataEndLBAExclusive: cursor,
            drawingStartLBA: drawingStart,
            drawingEndLBAExclusive: drawingEnd,
            filesAtOuterRing: filesAtOuterRing,
            partitionStartLBA: partitionStart,
            nodes: nodes
        )
    }

    // MARK: - 前缀 / 后缀写入

    /// 写卷前部（卷识别序列、主卷描述符、完整性描述符、锚点）与文件系统分区，
    /// 然后补零到 `endLBAExclusive`（= 绘图区起点）。
    public static func writePrefix(plan: LayoutPlan, to sink: SequentialSink, endLBAExclusive: UInt32) throws {
        guard endLBAExclusive >= (plan.filesAtOuterRing ? plan.drawingStartLBA : plan.dataEndLBAExclusive),
              endLBAExclusive <= plan.drawingEndLBAExclusive else {
            throw DiscError.io("UDF 前缀的结束位置不合法（\(endLBAExclusive)）")
        }
        try validateSources(plan)
        let writer = try UDFSequentialWriter(sink: sink, startLBA: 0)
        try writer.writeAt(lba: 16, volumeRecognition("BEA01"))
        try writer.writeAt(lba: 17, volumeRecognition("NSR03"))
        try writer.writeAt(lba: 18, volumeRecognition("TEA01"))
        try writeVolumeDescriptors(plan: plan, writer: writer, start: mainVDSLBA)
        try writer.writeAt(lba: integrityLBA, integrityDescriptor(plan: plan))
        try writer.writeAt(lba: integrityLBA + 1, descriptor(id: 8, location: integrityLBA + 1, length: 512))
        try writer.writeAt(lba: 256, anchor(plan: plan, location: 256))
        if !plan.filesAtOuterRing {
            try writePartition(plan: plan, writer: writer)
        }
        try writer.padTo(lba: endLBAExclusive)
        try validateSources(plan)
    }

    /// 写尾部：外圈分区（若需要）+ 备份卷描述符 + 锚点，并补零到卷尾。
    public static func writeSuffix(plan: LayoutPlan, to sink: SequentialSink, startLBA: UInt32) throws {
        guard startLBA == plan.drawingEndLBAExclusive else {
            throw DiscError.io("UDF 后缀必须从绘图区末尾开始（\(startLBA) ≠ \(plan.drawingEndLBAExclusive)）")
        }
        let writer = try UDFSequentialWriter(sink: sink, startLBA: startLBA)
        if plan.filesAtOuterRing {
            try validateSources(plan)
            try writePartition(plan: plan, writer: writer)
            try validateSources(plan)
        }
        try writer.writeAt(lba: plan.volumeSectors - 257, anchor(plan: plan, location: plan.volumeSectors - 257))
        try writeVolumeDescriptors(plan: plan, writer: writer, start: plan.reserveVDSLBA)
        try writer.writeAt(lba: plan.volumeSectors - 1, anchor(plan: plan, location: plan.volumeSectors - 1))
        try writer.padTo(lba: plan.volumeSectors)
    }

    // MARK: - 分区与文件

    static func writePartition(plan: LayoutPlan, writer: UDFSequentialWriter) throws {
        try writer.writeAt(lba: plan.partitionStartLBA, fileSetDescriptor(plan: plan))
        try writer.writeAt(lba: plan.partitionStartLBA + 1, descriptor(id: 8, location: 1, length: 512))
        for node in plan.nodes {
            try writer.writeAt(lba: node.entryLBA, fileEntry(plan: plan, node: node))
        }
        for directory in plan.nodes where directory.isDirectory {
            try writer.padTo(lba: directory.dataLBA)
            var directoryOffset = 0
            // 自己的父目录记录（根目录的父目录就是它自己）。
            var record = try fileIdentifier(
                plan: plan,
                directory: directory,
                target: directory.parent ?? directory,
                identifier: [],
                isParent: true,
                location: directory.dataLBA - plan.partitionStartLBA,
                directoryOffset: directoryOffset
            )
            try writer.write(record)
            directoryOffset += record.count
            for child in directory.children {
                record = try fileIdentifier(
                    plan: plan,
                    directory: directory,
                    target: child,
                    identifier: child.identifier,
                    isParent: false,
                    location: directory.dataLBA - plan.partitionStartLBA + UInt32(directoryOffset / logicalSectorBytes),
                    directoryOffset: directoryOffset
                )
                try writer.write(record)
                directoryOffset += record.count
            }
        }
        for file in plan.nodes where !file.isDirectory {
            try writer.padTo(lba: file.dataLBA)
            try writer.writeFile(file)
        }
    }

    // MARK: - 描述符

    static func volumeRecognition(_ identifier: String) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: logicalSectorBytes)
        let bytes = Array(identifier.utf8)
        data.replaceSubrange(1..<(1 + bytes.count), with: bytes)
        data[6] = 1
        return data
    }

    static func writeVolumeDescriptors(plan: LayoutPlan, writer: UDFSequentialWriter, start: UInt32) throws {
        try writer.writeAt(lba: start, primaryDescriptor(plan: plan, location: start))
        try writer.writeAt(lba: start + 1, implementationDescriptor(plan: plan, location: start + 1))
        try writer.writeAt(lba: start + 2, partitionDescriptor(plan: plan, location: start + 2))
        try writer.writeAt(lba: start + 3, logicalVolumeDescriptor(plan: plan, location: start + 3))
        var unallocated = [UInt8](repeating: 0, count: logicalSectorBytes)
        putUInt32(&unallocated, 16, 5)
        setTag(&unallocated, id: 7, location: start + 4, descriptorLength: 24)
        try writer.writeAt(lba: start + 4, unallocated)
        try writer.writeAt(lba: start + 5, descriptor(id: 8, location: start + 5, length: 512))
        try writer.padTo(lba: start + vdsSectors)
    }

    static func primaryDescriptor(plan: LayoutPlan, location: UInt32) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: logicalSectorBytes)
        putUInt32(&data, 16, 1)
        putDstring(&data, 24, 32, fitDstring(plan.volumeLabel, fieldBytes: 32))
        putUInt16(&data, 56, 1)
        putUInt16(&data, 58, 1)
        putUInt16(&data, 60, 2)
        putUInt16(&data, 62, 3)
        putUInt32(&data, 64, 1)
        putUInt32(&data, 68, 1)
        let seconds = UInt32(truncatingIfNeeded: Int64(plan.timestamp.timeIntervalSince1970))
        putDstring(&data, 72, 128, String(format: "%08X", seconds) + "00000000")
        putCharspec(&data, 200)
        putCharspec(&data, 264)
        putEntity(&data, 344, implementationID)
        putTimestamp(&data, 376, plan.timestamp)
        putEntity(&data, 388, implementationID)
        putUInt16(&data, 488, 1)
        setTag(&data, id: 1, location: location, descriptorLength: 512)
        return data
    }

    static func implementationDescriptor(plan: LayoutPlan, location: UInt32) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: logicalSectorBytes)
        putUInt32(&data, 16, 2)
        putEntity(&data, 20, "*UDF LV Info", udfRevision: true)
        putCharspec(&data, 52)
        putDstring(&data, 116, 128, plan.volumeLabel)
        putEntity(&data, 352, implementationID)
        setTag(&data, id: 4, location: location, descriptorLength: 512)
        return data
    }

    static func partitionDescriptor(plan: LayoutPlan, location: UInt32) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: logicalSectorBytes)
        putUInt32(&data, 16, 3)
        putUInt16(&data, 20, 1)
        putEntity(&data, 24, "+NSR03")
        putUInt32(&data, 184, 1)          // 只读分区：没有可分配空闲空间
        putUInt32(&data, 188, plan.partitionStartLBA)
        putUInt32(&data, 192, plan.partitionSectors)
        putEntity(&data, 196, implementationID)
        setTag(&data, id: 5, location: location, descriptorLength: 512)
        return data
    }

    static func logicalVolumeDescriptor(plan: LayoutPlan, location: UInt32) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: logicalSectorBytes)
        putUInt32(&data, 16, 4)
        putCharspec(&data, 20)
        putDstring(&data, 84, 128, plan.volumeLabel)
        putUInt32(&data, 212, UInt32(logicalSectorBytes))
        putEntity(&data, 216, "*OSTA UDF Compliant", domain: true)
        putLongAD(&data, 248, UInt32(logicalSectorBytes), 0)   // File Set Descriptor 在分区 LBN 0
        putUInt32(&data, 264, 6)          // 分区映射表长度
        putUInt32(&data, 268, 1)          // 分区映射数量
        putEntity(&data, 272, implementationID)
        putExtent(&data, 432, UInt32(logicalSectorBytes) * 4, integrityLBA)
        data[440] = 1                     // 分区映射类型 1（类型 1 分区）
        data[441] = 6                     // 分区映射长度 6
        putUInt16(&data, 442, 1)          // 卷序号；分区号在 444，保持 0
        setTag(&data, id: 6, location: location, descriptorLength: 446)
        return data
    }

    static func integrityDescriptor(plan: LayoutPlan) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: logicalSectorBytes)
        putTimestamp(&data, 16, plan.timestamp)
        putUInt32(&data, 28, 1)                        // 已关闭的逻辑卷
        putUInt64(&data, 40, UInt64(plan.nodes.count + 15))
        putUInt32(&data, 72, 1)                        // 分区数
        putUInt32(&data, 76, 46)                       // 实现使用区长度
        putUInt32(&data, 84, plan.partitionSectors)    // 分区大小表
        putEntity(&data, 88, implementationID)
        putUInt32(&data, 120, UInt32(plan.fileCount))
        putUInt32(&data, 124, UInt32(plan.directoryCount))
        putUInt16(&data, 128, 0x0201)
        putUInt16(&data, 130, 0x0201)
        putUInt16(&data, 132, 0x0201)
        setTag(&data, id: 9, location: integrityLBA, descriptorLength: 134)
        return data
    }

    static func anchor(plan: LayoutPlan, location: UInt32) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: logicalSectorBytes)
        putExtent(&data, 16, vdsSectors * UInt32(logicalSectorBytes), mainVDSLBA)
        putExtent(&data, 24, vdsSectors * UInt32(logicalSectorBytes), plan.reserveVDSLBA)
        setTag(&data, id: 2, location: location, descriptorLength: 512)
        return data
    }

    static func fileSetDescriptor(plan: LayoutPlan) -> [UInt8] {
        guard let root = plan.nodes.first else {
            return [UInt8](repeating: 0, count: logicalSectorBytes)
        }
        var data = [UInt8](repeating: 0, count: logicalSectorBytes)
        putTimestamp(&data, 16, plan.timestamp)
        putUInt16(&data, 28, 3)
        putUInt16(&data, 30, 3)
        putUInt32(&data, 32, 1)
        putUInt32(&data, 36, 1)
        putCharspec(&data, 48)
        putDstring(&data, 112, 128, plan.volumeLabel)
        putCharspec(&data, 240)
        putDstring(&data, 304, 32, fitDstring(plan.volumeLabel, fieldBytes: 32))
        putLongAD(&data, 400, UInt32(logicalSectorBytes), root.entryLBA - plan.partitionStartLBA)
        putEntity(&data, 416, "*OSTA UDF Compliant", domain: true)
        setTag(&data, id: 256, location: 0, descriptorLength: 512)
        return data
    }

    static func fileEntry(plan: LayoutPlan, node: UDFNode) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: logicalSectorBytes)
        putUInt16(&data, 20, 4)   // ICB strategy 4，短分配描述符
        putUInt16(&data, 24, 1)
        data[27] = node.isDirectory ? 4 : 5
        putUInt32(&data, 28, (node.parent ?? node).entryLBA - plan.partitionStartLBA)
        putUInt16(&data, 34, 0)
        putUInt32(&data, 36, UInt32.max)
        putUInt32(&data, 40, UInt32.max)
        putUInt32(&data, 44, node.isDirectory ? 0x14A5 : 0x1084)
        putUInt16(&data, 48, UInt16(node.isDirectory
            ? 1 + node.children.filter { $0.isDirectory }.count
            : 1))
        putUInt64(&data, 56, UInt64(node.dataLength))
        putUInt64(&data, 64, UInt64(sectorCount(node.dataLength)))
        putTimestamp(&data, 72, node.timestamp)
        putTimestamp(&data, 84, node.timestamp)
        putTimestamp(&data, 96, node.timestamp)
        putUInt32(&data, 108, 1)
        putEntity(&data, 128, implementationID)
        putUInt64(&data, 160, node.uniqueID)
        var offset = 176
        var remaining = node.dataLength
        var lbn = node.dataLBA - plan.partitionStartLBA
        while remaining > 0 {
            let length = min(remaining, maximumExtentBytes)
            putUInt32(&data, offset, UInt32(length))
            putUInt32(&data, offset + 4, lbn)
            remaining -= length
            lbn = lbn &+ UInt32((length + Int64(logicalSectorBytes) - 1) / Int64(logicalSectorBytes))
            offset += 8
        }
        putUInt32(&data, 172, UInt32(offset - 176))
        setTag(&data, id: 261, location: node.entryLBA - plan.partitionStartLBA, descriptorLength: offset)
        return data
    }

    static func fileIdentifier(
        plan: LayoutPlan,
        directory: UDFNode,
        target: UDFNode,
        identifier: [UInt8],
        isParent: Bool,
        location: UInt32,
        directoryOffset: Int
    ) throws -> [UInt8] {
        let length = fileIdentifierLength(identifierBytes: identifier.count, directoryOffset: directoryOffset)
        var data = [UInt8](repeating: 0, count: length)
        let base = ((38 + identifier.count + 3) / 4) * 4
        let implementationBytes = length - base
        putUInt16(&data, 16, 1)
        data[18] = isParent ? 10 : (target.isDirectory ? 2 : 0)
        data[19] = UInt8(identifier.count)
        putLongAD(&data, 20, UInt32(logicalSectorBytes), target.entryLBA - plan.partitionStartLBA)
        putUInt32(&data, 32, UInt32(target.uniqueID))
        putUInt16(&data, 36, UInt16(implementationBytes))
        if implementationBytes > 0 {
            putEntity(&data, 38, implementationID)
        }
        data.replaceSubrange((38 + implementationBytes)..<(38 + implementationBytes + identifier.count), with: identifier)
        setTag(&data, id: 257, location: location, descriptorLength: data.count)
        return data
    }

    // MARK: - 目录扫描

    struct ScannedEntry {
        let url: URL
        let isDirectory: Bool
        let byteCount: Int64
        let timestamp: Date
    }

    static func listDirectory(at url: URL) throws -> [ScannedEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .nameKey]
        var contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: []
            )
        } catch {
            throw DiscError.io("无法读取目录 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
        contents.sort { $0.lastPathComponent < $1.lastPathComponent }
        return try contents.map { child in
            let values = try child.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw DiscError.io("数据目录里含符号链接，已拒绝：\(child.lastPathComponent)")
            }
            let isDirectory = values.isDirectory == true
            return ScannedEntry(
                url: child,
                isDirectory: isDirectory,
                byteCount: isDirectory ? 0 : Int64(values.fileSize ?? 0),
                timestamp: values.contentModificationDate ?? Date()
            )
        }
    }

    static func validateSources(_ plan: LayoutPlan) throws {
        guard plan.sourceDirectory != nil else { return }
        for node in plan.nodes {
            guard !node.sourcePath.isEmpty else { continue }
            let url = URL(fileURLWithPath: node.sourcePath)
            if try isSymbolicLink(url) {
                throw DiscError.io("源目录在规划后变成了符号链接：\(node.name)")
            }
            if node.isDirectory {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw DiscError.io("源目录在 UDF 规划后消失：\(node.name)")
                }
                let current = Set(try listDirectory(at: url).map { $0.url.lastPathComponent })
                let expected = Set(node.children.map { $0.name })
                guard current == expected else {
                    throw DiscError.io("源目录在 UDF 规划后发生变化：\(node.name)")
                }
            } else {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    throw DiscError.io("源文件在规划后变成了符号链接：\(node.name)")
                }
                guard Int64(values.fileSize ?? -1) == node.dataLength else {
                    throw DiscError.io("源文件大小在 UDF 规划后发生变化：\(node.name)")
                }
                let date = values.contentModificationDate ?? Date()
                guard abs(date.timeIntervalSince(node.timestamp)) <= 0.001 else {
                    throw DiscError.io("源文件修改时间在 UDF 规划后发生变化：\(node.name)")
                }
            }
        }
    }

    // MARK: - 工具

    static func sectorCount(_ length: Int64) -> UInt32 {
        UInt32((length + Int64(logicalSectorBytes) - 1) / Int64(logicalSectorBytes))
    }

    /// 目录记录（FID）长度。UDF 2.01 §2.3.4.4：写一次介质上后续 FID 的
    /// 16 字节描述符标签不能跨扇区，必要时补 32 字节实现使用区。
    static func fileIdentifierLength(identifierBytes: Int, directoryOffset: Int) -> Int {
        let length = ((38 + identifierBytes + 3) / 4) * 4
        let nextOffset = (directoryOffset + length) % logicalSectorBytes
        return nextOffset > logicalSectorBytes - 16 ? length + 32 : length
    }

    /// CS0 压缩 Unicode 标识符：全 ASCII 用 8 位，否则 16 位大端。
    static func encodeIdentifier(_ text: String) throws -> [UInt8] {
        for scalar in text.unicodeScalars {
            if scalar.value == 0 || scalar.value == 0xFEFF || scalar.value == 0xFFFE {
                throw DiscError.io("UDF 文件名包含不允许的字符：\(text)")
            }
        }
        let narrow = text.unicodeScalars.allSatisfy { $0.value <= 0xFF }
        let length = 1 + text.unicodeScalars.count * (narrow ? 1 : 2)
        guard length <= 255 else {
            throw DiscError.io("文件名超过 UDF CS0 标识符上限（254 单字节 / 127 双字节）：\(text)")
        }
        var bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = narrow ? 8 : 16
        if narrow {
            var index = 1
            for scalar in text.unicodeScalars {
                bytes[index] = UInt8(scalar.value)
                index += 1
            }
        } else {
            var index = 1
            for unit in text.utf16 {
                bytes[index] = UInt8(unit >> 8)
                bytes[index + 1] = UInt8(unit & 0xFF)
                index += 2
            }
        }
        return bytes
    }

    static func fitDstring(_ text: String, fieldBytes: Int) -> String {
        let characters = text.unicodeScalars.allSatisfy { $0.value <= 0xFF }
            ? fieldBytes - 2
            : (fieldBytes - 2) / 2
        guard text.count > characters else { return text }
        return String(text.prefix(characters))
    }

    static func putDstring(_ data: inout [UInt8], _ offset: Int, _ fieldBytes: Int, _ text: String) {
        guard !text.isEmpty else { return }
        guard let bytes = try? encodeIdentifier(text), bytes.count < fieldBytes else { return }
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        data[offset + fieldBytes - 1] = UInt8(bytes.count)
    }

    static func putCharspec(_ data: inout [UInt8], _ offset: Int) {
        let text = Array("OSTA Compressed Unicode".utf8)
        data.replaceSubrange((offset + 1)..<(offset + 1 + text.count), with: text)
    }

    static func putEntity(
        _ data: inout [UInt8],
        _ offset: Int,
        _ identifier: String,
        domain: Bool = false,
        udfRevision: Bool = false
    ) {
        let text = Array(identifier.utf8)
        data.replaceSubrange((offset + 1)..<(offset + 1 + min(23, text.count)), with: text.prefix(23))
        if domain || udfRevision {
            putUInt16(&data, offset + 24, 0x0201)
        }
        if domain {
            data[offset + 26] = 1   // 永久关闭、写保护
        }
    }

    static func putTimestamp(_ data: inout [UInt8], _ offset: Int, _ date: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let ticks = Int64((parts.nanosecond ?? 0) / 100)   // 100 ns 单位（秒内）
        putUInt16(&data, offset, 0x1000)                   // 本地时间、UTC 偏移 0
        putUInt16(&data, offset + 2, UInt16(parts.year ?? 1970))
        data[offset + 4] = UInt8(parts.month ?? 1)
        data[offset + 5] = UInt8(parts.day ?? 1)
        data[offset + 6] = UInt8(parts.hour ?? 0)
        data[offset + 7] = UInt8(parts.minute ?? 0)
        data[offset + 8] = UInt8(parts.second ?? 0)
        data[offset + 9] = UInt8((ticks / 10_000) % 100)   // 厘秒
        data[offset + 10] = UInt8((ticks / 1_000) % 100)
        data[offset + 11] = UInt8((ticks / 10) % 100)
    }

    static func putExtent(_ data: inout [UInt8], _ offset: Int, _ length: UInt32, _ lba: UInt32) {
        putUInt32(&data, offset, length)
        putUInt32(&data, offset + 4, lba)
    }

    static func putLongAD(_ data: inout [UInt8], _ offset: Int, _ length: UInt32, _ lbn: UInt32) {
        putExtent(&data, offset, length, lbn)
        // 分区引用号（offset+8，2 字节）保持 0：只有一个分区。
    }

    static func descriptor(id: UInt16, location: UInt32, length: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: logicalSectorBytes)
        setTag(&data, id: id, location: location, descriptorLength: length)
        return data
    }

    /// 写入 16 字节描述符标签：CRC-CCITT（初值 0、多项式 0x1021）覆盖 16..<length。
    static func setTag(_ data: inout [UInt8], id: UInt16, location: UInt32, descriptorLength: Int) {
        putUInt16(&data, 0, id)
        putUInt16(&data, 2, 3)      // ECMA-167 第 3 版
        putUInt16(&data, 6, 1)      // 序列号
        var crc: UInt16 = 0
        if descriptorLength > 16 {
            for index in 16..<min(descriptorLength, data.count) {
                crc ^= UInt16(data[index]) << 8
                for _ in 0..<8 {
                    crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : (crc << 1)
                }
            }
        }
        putUInt16(&data, 8, crc)
        putUInt16(&data, 10, UInt16(descriptorLength - 16))
        putUInt32(&data, 12, location)
        var checksum = 0
        for index in 0..<16 where index != 4 {
            checksum += Int(data[index])
        }
        data[4] = UInt8(checksum & 0xFF)
    }

    static func putUInt16(_ data: inout [UInt8], _ offset: Int, _ value: UInt16) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    static func putUInt32(_ data: inout [UInt8], _ offset: Int, _ value: UInt32) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    static func putUInt64(_ data: inout [UInt8], _ offset: Int, _ value: UInt64) {
        putUInt32(&data, offset, UInt32(value & 0xFFFF_FFFF))
        putUInt32(&data, offset + 4, UInt32((value >> 32) & 0xFFFF_FFFF))
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func isSymbolicLink(_ url: URL) throws -> Bool {
        (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true
    }
}

/// UDF 目录树节点。`parent` 为弱引用，避免与 `children` 形成环。
final class UDFNode {
    let sourcePath: String
    let name: String
    let isDirectory: Bool
    weak var parent: UDFNode?
    var children: [UDFNode] = []
    let timestamp: Date
    let identifier: [UInt8]
    let uniqueID: UInt64
    var dataLength: Int64
    var entryLBA: UInt32 = 0
    var dataLBA: UInt32 = 0

    init(
        sourcePath: String,
        name: String,
        isDirectory: Bool,
        parent: UDFNode?,
        timestamp: Date,
        identifier: [UInt8],
        uniqueID: UInt64,
        dataLength: Int64
    ) {
        self.sourcePath = sourcePath
        self.name = name
        self.isDirectory = isDirectory
        self.parent = parent
        self.timestamp = timestamp
        self.identifier = identifier
        self.uniqueID = uniqueID
        self.dataLength = dataLength
    }
}

/// 前向顺序写入器：带字节游标，禁止回退。
final class UDFSequentialWriter {
    private let sink: SequentialSink
    private var position: Int64
    private let zeroBuffer = [UInt8](repeating: 0, count: 128 * 1024)

    init(sink: SequentialSink, startLBA: UInt32) throws {
        self.sink = sink
        position = Int64(startLBA) * Int64(UDFImageWriter.logicalSectorBytes)
    }

    func write(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        try sink.write(bytes)
        position += Int64(bytes.count)
    }

    func writeAt(lba: UInt32, _ bytes: [UInt8]) throws {
        try padTo(lba: lba)
        try write(bytes)
    }

    func padTo(lba: UInt32) throws {
        let target = Int64(lba) * Int64(UDFImageWriter.logicalSectorBytes)
        guard target >= position else {
            throw DiscError.io("UDF 顺序写入不能回退（当前位置 \(position)，目标 \(target)）")
        }
        while position < target {
            let count = Int(min(Int64(zeroBuffer.count), target - position))
            try sink.write(Array(zeroBuffer[0..<count]))
            position += Int64(count)
        }
    }

    /// 顺序流式写入一个文件，写入前后各校验一次大小（防止规划后源文件被改）。
    func writeFile(_ file: UDFNode) throws {
        let url = URL(fileURLWithPath: file.sourcePath)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DiscError.io("无法读取文件 \(file.name)：\(error.localizedDescription)")
        }
        defer { try? handle.close() }
        var remaining = file.dataLength
        while remaining > 0 {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: Int(min(remaining, 128 * 1024)))
            } catch {
                throw DiscError.io("读取文件失败 \(file.name)：\(error.localizedDescription)")
            }
            guard let chunk, !chunk.isEmpty else {
                throw DiscError.io("文件在写入 UDF 时提前结束：\(file.name)")
            }
            try sink.write(chunk)
            position += Int64(chunk.count)
            remaining -= Int64(chunk.count)
        }
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard Int64(size ?? -1) == file.dataLength else {
            throw DiscError.io("文件在写入 UDF 时大小发生变化：\(file.name)")
        }
    }
}
