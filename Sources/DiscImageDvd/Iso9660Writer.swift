import DiscImageCore
import Foundation

/// ISO9660 卷布局计划（主 VD + Joliet SVD + 路径表 + 目录记录）。
///
/// 计划与写入分离的原因：DVD 数据盘要把「图片区」插在文件系统中间或外圈，
/// 而输出是只能前向写的 `SequentialSink`。先算好每个 extent 的 LBA，
/// 再由调用方按 LBA 顺序写（元数据 → [内圈文件] → 绘图区 → [外圈文件]）。
///
/// 这个类型**只依赖 DiscImageCore**（`FileTreeEntry` / `SequentialSink`），
/// CD 数据盘（工作包 B）直接复用。
public struct Iso9660LayoutPlan {
    public let volumeSectors: Int
    public let volumeLabel: String
    public let filesAtOuterRing: Bool
    /// 文件系统元数据（VD/路径表/目录）结束的 LBA（不含）。
    public let metadataEndLbaExclusive: Int
    /// 全部占位结束的 LBA（不含）：内圈布局 = 元数据 + 文件；外圈布局 = 卷尾。
    public let dataEndLbaExclusive: Int
    /// 第一个文件数据的 LBA（没有文件时等于元数据结束）。
    public let fileDataStartLba: Int
    public let fileCount: Int
    public let directoryCount: Int
    public let fileBytes: Int64

    let root: Iso9660Node
    let directories: [Iso9660Node]
    let files: [Iso9660Node]
    let timestamp: Date
    let primaryVolumeLabel: String
    let jolietVolumeLabel: String
    let primaryPathTableBytes: Int
    let jolietPathTableBytes: Int
    let primaryLittlePathTableLba: Int
    let primaryBigPathTableLba: Int
    let jolietLittlePathTableLba: Int
    let jolietBigPathTableLba: Int
}

/// ISO9660 卷的一个节点（文件或目录），只在写入器内部使用。
final class Iso9660Node {
    let name: String
    let relativePath: String
    let sourceURL: URL?
    let isDirectory: Bool
    var dataLength: Int64
    var children: [Iso9660Node] = []
    weak var parent: Iso9660Node?

    var directoryNumber = 0
    var primaryIdentifier = ""
    var jolietIdentifier = ""
    var primaryDirectoryLba = 0
    var primaryDirectoryBytes = 0
    var jolietDirectoryLba = 0
    var jolietDirectoryBytes = 0
    var dataLba = 0

    init(
        name: String,
        relativePath: String,
        sourceURL: URL?,
        isDirectory: Bool,
        parent: Iso9660Node?,
        dataLength: Int64 = 0
    ) {
        self.name = name
        self.relativePath = relativePath
        self.sourceURL = sourceURL
        self.isDirectory = isDirectory
        self.parent = parent
        self.dataLength = dataLength
    }

    func addChild(_ child: Iso9660Node) {
        children.append(child)
    }
}

/// ISO9660 / Joliet 写入器。
///
/// 与源项目 `DiscImageStudio.Iso.Iso9660ImageWriter` 同构：
/// - LBA 16：主卷描述符（PVD），LBA 17：Joliet 补充卷描述符（SVD），LBA 18：终止符；
/// - LBA 19 起依次分配 4 张路径表（主/辅 × 小端/大端）与目录 extent；
/// - 文件默认紧跟元数据（内圈）；`filesAtOuterRing` 时贴卷尾（外圈）；
/// - 标识符：主卷 8.3 风格大写（31 字符上限，文件加 `;1`），Joliet 保留 Unicode（60 字符上限）；
/// - 重复名加 `~N` 区分；单文件上限 4 GiB − 1；符号链接一律拒绝。
public enum Iso9660Writer {
    public static let logicalSectorBytes = 2048

    private static let primaryVolumeDescriptorLba = 16
    private static let supplementaryVolumeDescriptorLba = 17
    private static let terminatorLba = 18
    private static let firstMetadataLba = 19
    private static let maximumPrimaryIdentifierCharacters = 31
    private static let maximumJolietIdentifierCharacters = 60

    // MARK: - 计划

    /// 扫描 `entries`（`FileTree.scan` 的输出）并规划整卷布局。
    public static func plan(
        entries: [FileTreeEntry],
        volumeSectors: Int,
        volumeLabel: String,
        filesAtOuterRing: Bool = false,
        timestamp: Date = Date()
    ) throws -> Iso9660LayoutPlan {
        guard volumeSectors > firstMetadataLba else {
            throw DiscError.invalidGeometry("ISO9660 卷太小：至少要 \(firstMetadataLba + 1) 个扇区（当前 \(volumeSectors)）")
        }
        guard volumeSectors <= Int(UInt32.max) else {
            throw DiscError.invalidGeometry("ISO9660 卷的扇区数超过 32 位范围")
        }
        guard !volumeLabel.isEmpty else {
            throw DiscError.invalidGeometry("卷标不能为空")
        }

        let root = try buildTree(entries: entries)
        let directories = assignDirectoryNumbers(root)
        assignIdentifiers(directories)
        let files = enumerateFiles(root)
        let layout = try buildLayout(
            directories: directories,
            files: files,
            volumeSectors: volumeSectors,
            filesAtOuterRing: filesAtOuterRing
        )

        return Iso9660LayoutPlan(
            volumeSectors: volumeSectors,
            volumeLabel: volumeLabel,
            filesAtOuterRing: filesAtOuterRing,
            metadataEndLbaExclusive: layout.metadataEndLbaExclusive,
            dataEndLbaExclusive: layout.dataEndLbaExclusive,
            fileDataStartLba: layout.fileDataStartLba,
            fileCount: files.count,
            directoryCount: directories.count,
            fileBytes: files.reduce(0) { $0 + $1.dataLength },
            root: root,
            directories: directories,
            files: files,
            timestamp: timestamp,
            primaryVolumeLabel: normalizePrimaryIdentifier(volumeLabel, maximumLength: 32, fallback: "DISC_IMAGE"),
            jolietVolumeLabel: normalizeJolietIdentifier(volumeLabel, maximumLength: 16, fallback: "DISC_IMAGE"),
            primaryPathTableBytes: layout.primaryPathTableBytes,
            jolietPathTableBytes: layout.jolietPathTableBytes,
            primaryLittlePathTableLba: layout.primaryLittlePathTableLba,
            primaryBigPathTableLba: layout.primaryBigPathTableLba,
            jolietLittlePathTableLba: layout.jolietLittlePathTableLba,
            jolietBigPathTableLba: layout.jolietBigPathTableLba
        )
    }

    // MARK: - 写入

    /// 写元数据：卷描述符、路径表、目录 extent，最后补零到 `metadataEndLbaExclusive`。
    ///
    /// 要求 sink 当前位置 ≤ LBA 16；从 LBA 0（系统区）开始由本方法负责补零。
    public static func writeMetadata(_ plan: Iso9660LayoutPlan, to sink: SequentialSink) throws {
        let writer = SequentialIsoWriter(sink: sink)
        try writer.writeAtLba(primaryVolumeDescriptorLba, buildVolumeDescriptor(
            plan: plan,
            type: 1,
            label: plan.primaryVolumeLabel,
            joliet: false,
            pathTableBytes: plan.primaryPathTableBytes,
            littlePathTableLba: plan.primaryLittlePathTableLba,
            bigPathTableLba: plan.primaryBigPathTableLba,
            rootLba: plan.root.primaryDirectoryLba,
            rootBytes: plan.root.primaryDirectoryBytes
        ))
        try writer.writeAtLba(supplementaryVolumeDescriptorLba, buildVolumeDescriptor(
            plan: plan,
            type: 2,
            label: plan.jolietVolumeLabel,
            joliet: true,
            pathTableBytes: plan.jolietPathTableBytes,
            littlePathTableLba: plan.jolietLittlePathTableLba,
            bigPathTableLba: plan.jolietBigPathTableLba,
            rootLba: plan.root.jolietDirectoryLba,
            rootBytes: plan.root.jolietDirectoryBytes
        ))
        try writer.writeAtLba(terminatorLba, buildTerminator())

        try writer.writeAtLba(plan.primaryLittlePathTableLba, buildPathTable(plan.directories, littleEndian: true, joliet: false))
        try writer.writeAtLba(plan.primaryBigPathTableLba, buildPathTable(plan.directories, littleEndian: false, joliet: false))
        try writer.writeAtLba(plan.jolietLittlePathTableLba, buildPathTable(plan.directories, littleEndian: true, joliet: true))
        try writer.writeAtLba(plan.jolietBigPathTableLba, buildPathTable(plan.directories, littleEndian: false, joliet: true))

        for directory in plan.directories {
            try writer.writeAtLba(
                directory.primaryDirectoryLba,
                buildDirectoryExtent(directory, joliet: false, timestamp: plan.timestamp)
            )
        }
        for directory in plan.directories {
            try writer.writeAtLba(
                directory.jolietDirectoryLba,
                buildDirectoryExtent(directory, joliet: true, timestamp: plan.timestamp)
            )
        }

        try writer.pad(toLba: plan.metadataEndLbaExclusive)
    }

    /// 写文件数据：按计划 LBA 补零后逐个文件流式拷贝。
    ///
    /// - `padToVolumeEnd = true` 时最后补零到卷尾；内圈布局可以直接用 `false`
    ///   让调用方接管绘图区。
    /// - 每个文件写入前后都会检查大小与符号链接，防止规划后被替换。
    public static func writeFileData(
        _ plan: Iso9660LayoutPlan,
        to sink: SequentialSink,
        padToVolumeEnd: Bool = true
    ) throws {
        for file in plan.files {
            try validateSourceFile(file)
            if file.dataLength == 0 { continue }
            try sink.pad(to: Int64(file.dataLba) * Int64(logicalSectorBytes), with: 0)
            try writeContents(of: file, to: sink)
            try validateSourceFile(file)
        }
        if padToVolumeEnd {
            try sink.pad(to: Int64(plan.volumeSectors) * Int64(logicalSectorBytes), with: 0)
        }
    }

    /// 一次写完整个卷（元数据 + 内圈文件 + 补零到卷尾）。
    ///
    /// 外圈布局（`filesAtOuterRing`）不要用这个入口：绘图区要插在元数据和文件之间，
    /// 请分别调用 `writeMetadata` 与 `writeFileData`。
    public static func writeAll(_ plan: Iso9660LayoutPlan, to sink: SequentialSink) throws {
        try writeMetadata(plan, to: sink)
        try writeFileData(plan, to: sink, padToVolumeEnd: true)
    }

    // MARK: - 树构建

    private static func buildTree(entries: [FileTreeEntry]) throws -> Iso9660Node {
        let root = Iso9660Node(
            name: "",
            relativePath: "",
            sourceURL: nil,
            isDirectory: true,
            parent: nil
        )
        var nodes: [String: Iso9660Node] = ["": root]

        // 先浅后深：父目录一定先于子项出现。
        let sorted = entries.sorted { lhs, rhs in
            let left = lhs.relativePath.split(separator: "/").count
            let right = rhs.relativePath.split(separator: "/").count
            if left != right { return left < right }
            return lhs.relativePath < rhs.relativePath
        }

        for entry in sorted {
            let components = try pathComponents(entry.relativePath)
            var parent = root
            var path = ""
            for (index, component) in components.enumerated() {
                let isLast = index == components.count - 1
                path = path.isEmpty ? component : path + "/" + component
                if let existing = nodes[path] {
                    guard !isLast else {
                        throw DiscError.io("数据盘里出现重复路径：\(entry.relativePath)")
                    }
                    guard existing.isDirectory else {
                        throw DiscError.io("路径「\(path)」既是文件又是目录")
                    }
                    parent = existing
                    continue
                }
                if isLast {
                    if entry.isDirectory {
                        let node = Iso9660Node(
                            name: component,
                            relativePath: path,
                            sourceURL: entry.sourceURL,
                            isDirectory: true,
                            parent: parent
                        )
                        parent.addChild(node)
                        nodes[path] = node
                        parent = node
                    } else {
                        guard entry.byteCount >= 0 else {
                            throw DiscError.io("文件大小非法：\(entry.relativePath)")
                        }
                        guard entry.byteCount <= Int64(UInt32.max) else {
                            throw DiscError.unsupported(
                                "ISO9660 单个文件不能超过 4 GiB − 1 字节：\(entry.relativePath)"
                            )
                        }
                        try validateSourceFile(entry: entry)
                        let node = Iso9660Node(
                            name: component,
                            relativePath: path,
                            sourceURL: entry.sourceURL,
                            isDirectory: false,
                            parent: parent,
                            dataLength: entry.byteCount
                        )
                        parent.addChild(node)
                        nodes[path] = node
                        parent = node
                    }
                } else {
                    let node = Iso9660Node(
                        name: component,
                        relativePath: path,
                        sourceURL: nil,
                        isDirectory: true,
                        parent: parent
                    )
                    parent.addChild(node)
                    nodes[path] = node
                    parent = node
                }
            }
        }

        sortChildren(root)
        return root
    }

    private static func pathComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.hasPrefix("/") else {
            throw DiscError.io("数据盘条目路径必须是相对路径：\(relativePath)")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty else {
            throw DiscError.io("数据盘条目路径为空")
        }
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw DiscError.io("数据盘条目路径非法：\(relativePath)")
            }
        }
        return components
    }

    private static func sortChildren(_ node: Iso9660Node) {
        node.children.sort { lhs, rhs in
            let left = lhs.name.lowercased()
            let right = rhs.name.lowercased()
            if left != right { return left < right }
            return lhs.name < rhs.name
        }
        for child in node.children where child.isDirectory {
            sortChildren(child)
        }
    }

    private static func assignDirectoryNumbers(_ root: Iso9660Node) -> [Iso9660Node] {
        var directories: [Iso9660Node] = []
        var queue: [Iso9660Node] = [root]
        var head = 0
        while head < queue.count {
            let directory = queue[head]
            head += 1
            directory.directoryNumber = directories.count + 1
            directories.append(directory)
            for child in directory.children where child.isDirectory {
                queue.append(child)
            }
        }
        return directories
    }

    private static func assignIdentifiers(_ directories: [Iso9660Node]) {
        for directory in directories {
            var primaryUsed = Set<String>()
            var jolietUsed = Set<String>()
            for child in directory.children {
                let primaryBase = normalizePrimaryIdentifier(
                    child.name,
                    maximumLength: child.isDirectory
                        ? maximumPrimaryIdentifierCharacters
                        : maximumPrimaryIdentifierCharacters - 2,
                    fallback: child.isDirectory ? "DIRECTORY" : "FILE"
                )
                child.primaryIdentifier = makeUnique(
                    base: primaryBase,
                    used: &primaryUsed,
                    suffix: child.isDirectory ? "" : ";1",
                    maximumLength: maximumPrimaryIdentifierCharacters
                )

                let jolietBase = normalizeJolietIdentifier(
                    child.name,
                    maximumLength: child.isDirectory
                        ? maximumJolietIdentifierCharacters
                        : maximumJolietIdentifierCharacters - 2,
                    fallback: child.isDirectory ? "Directory" : "File"
                )
                child.jolietIdentifier = makeUnique(
                    base: jolietBase,
                    used: &jolietUsed,
                    suffix: child.isDirectory ? "" : ";1",
                    maximumLength: maximumJolietIdentifierCharacters
                )
            }
        }
    }

    private static func enumerateFiles(_ root: Iso9660Node) -> [Iso9660Node] {
        var files: [Iso9660Node] = []
        func walk(_ node: Iso9660Node) {
            for child in node.children {
                if child.isDirectory {
                    walk(child)
                } else {
                    files.append(child)
                }
            }
        }
        walk(root)
        return files
    }

    // MARK: - 布局

    private struct Layout {
        let primaryPathTableBytes: Int
        let jolietPathTableBytes: Int
        let primaryLittlePathTableLba: Int
        let primaryBigPathTableLba: Int
        let jolietLittlePathTableLba: Int
        let jolietBigPathTableLba: Int
        let metadataEndLbaExclusive: Int
        let dataEndLbaExclusive: Int
        let fileDataStartLba: Int
    }

    private static func buildLayout(
        directories: [Iso9660Node],
        files: [Iso9660Node],
        volumeSectors: Int,
        filesAtOuterRing: Bool
    ) throws -> Layout {
        let primaryPathTableBytes = pathTableLength(directories, joliet: false)
        let jolietPathTableBytes = pathTableLength(directories, joliet: true)
        var cursor = firstMetadataLba
        let primaryLittle = allocate(&cursor, primaryPathTableBytes)
        let primaryBig = allocate(&cursor, primaryPathTableBytes)
        let jolietLittle = allocate(&cursor, jolietPathTableBytes)
        let jolietBig = allocate(&cursor, jolietPathTableBytes)

        for directory in directories {
            directory.primaryDirectoryBytes = directoryExtentLength(directory, joliet: false)
            directory.primaryDirectoryLba = allocate(&cursor, directory.primaryDirectoryBytes)
        }
        for directory in directories {
            directory.jolietDirectoryBytes = directoryExtentLength(directory, joliet: true)
            directory.jolietDirectoryLba = allocate(&cursor, directory.jolietDirectoryBytes)
        }

        let metadataEnd = cursor
        var fileSectors = 0
        for file in files {
            fileSectors += sectorCount(file.dataLength)
        }
        guard metadataEnd + fileSectors <= volumeSectors else {
            throw DiscError.unsupported(
                "数据文件夹放不下：元数据 + 文件需要 \(metadataEnd + fileSectors) 个扇区，盘上只有 \(volumeSectors) 个"
            )
        }
        if filesAtOuterRing {
            cursor = volumeSectors - fileSectors
        }
        let fileDataStart = cursor
        for file in files {
            file.dataLba = (filesAtOuterRing && file.dataLength == 0) ? 0 : cursor
            cursor += sectorCount(file.dataLength)
        }
        guard cursor <= volumeSectors else {
            throw DiscError.unsupported("数据文件夹放不下：需要 \(cursor) 个扇区，盘上只有 \(volumeSectors) 个")
        }

        return Layout(
            primaryPathTableBytes: primaryPathTableBytes,
            jolietPathTableBytes: jolietPathTableBytes,
            primaryLittlePathTableLba: primaryLittle,
            primaryBigPathTableLba: primaryBig,
            jolietLittlePathTableLba: jolietLittle,
            jolietBigPathTableLba: jolietBig,
            metadataEndLbaExclusive: metadataEnd,
            dataEndLbaExclusive: cursor,
            fileDataStartLba: fileDataStart
        )
    }

    private static func allocate(_ cursor: inout Int, _ byteCount: Int) -> Int {
        let lba = cursor
        cursor += sectorCount(byteCount)
        return lba
    }

    private static func sectorCount(_ byteCount: Int) -> Int {
        (byteCount + logicalSectorBytes - 1) / logicalSectorBytes
    }

    private static func sectorCount(_ byteCount: Int64) -> Int {
        byteCount <= 0 ? 0 : Int((byteCount + Int64(logicalSectorBytes) - 1) / Int64(logicalSectorBytes))
    }

    // MARK: - 目录 / 路径表

    private static func pathTableLength(_ directories: [Iso9660Node], joliet: Bool) -> Int {
        var length = 0
        for directory in directories {
            let identifierBytes = directory.parent == nil ? 1 : identifierBytes(directory, joliet: joliet).count
            length += 8 + identifierBytes + (identifierBytes & 1)
        }
        return length
    }

    private static func directoryExtentLength(_ directory: Iso9660Node, joliet: Bool) -> Int {
        var recordLengths = [directoryRecordLength(1), directoryRecordLength(1)]
        for child in directory.children {
            recordLengths.append(directoryRecordLength(identifierBytes(child, joliet: joliet).count))
        }
        return packedRecordLength(recordLengths)
    }

    private static func packedRecordLength(_ recordLengths: [Int]) -> Int {
        var offset = 0
        for recordLength in recordLengths {
            let sectorOffset = offset % logicalSectorBytes
            if sectorOffset + recordLength > logicalSectorBytes {
                offset += logicalSectorBytes - sectorOffset
            }
            offset += recordLength
        }
        return sectorCount(offset) * logicalSectorBytes
    }

    private static func directoryRecordLength(_ identifierBytes: Int) -> Int {
        33 + identifierBytes + (identifierBytes % 2 == 0 ? 1 : 0)
    }

    private static func identifierBytes(_ node: Iso9660Node, joliet: Bool) -> [UInt8] {
        joliet ? utf16BigEndian(node.jolietIdentifier) : Array(node.primaryIdentifier.utf8)
    }

    private static func buildPathTable(
        _ directories: [Iso9660Node],
        littleEndian: Bool,
        joliet: Bool
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        for directory in directories {
            let identifier: [UInt8] = directory.parent == nil ? [0] : identifierBytes(directory, joliet: joliet)
            bytes.append(UInt8(identifier.count))
            bytes.append(0)
            let extent = joliet ? directory.jolietDirectoryLba : directory.primaryDirectoryLba
            appendUInt32(&bytes, UInt32(extent), littleEndian: littleEndian)
            appendUInt16(&bytes, UInt16(directory.parent?.directoryNumber ?? 1), littleEndian: littleEndian)
            bytes.append(contentsOf: identifier)
            if identifier.count % 2 == 1 {
                bytes.append(0)
            }
        }
        return bytes
    }

    private static func buildDirectoryExtent(
        _ directory: Iso9660Node,
        joliet: Bool,
        timestamp: Date
    ) -> [UInt8] {
        let extentBytes = joliet ? directory.jolietDirectoryBytes : directory.primaryDirectoryBytes
        var extent = [UInt8](repeating: 0, count: extentBytes)
        var offset = 0

        func add(_ record: [UInt8]) {
            let sectorOffset = offset % logicalSectorBytes
            if sectorOffset + record.count > logicalSectorBytes {
                offset += logicalSectorBytes - sectorOffset
            }
            extent.replaceSubrange(offset..<(offset + record.count), with: record)
            offset += record.count
        }

        let currentLba = joliet ? directory.jolietDirectoryLba : directory.primaryDirectoryLba
        let parent = directory.parent ?? directory
        let parentLba = joliet ? parent.jolietDirectoryLba : parent.primaryDirectoryLba
        let parentBytes = joliet ? parent.jolietDirectoryBytes : parent.primaryDirectoryBytes

        add(buildDirectoryRecord(
            extentLba: currentLba,
            dataLength: extentBytes,
            isDirectory: true,
            identifier: [0],
            timestamp: timestamp
        ))
        add(buildDirectoryRecord(
            extentLba: parentLba,
            dataLength: parentBytes,
            isDirectory: true,
            identifier: [1],
            timestamp: timestamp
        ))
        for child in directory.children {
            let childLba = child.isDirectory
                ? (joliet ? child.jolietDirectoryLba : child.primaryDirectoryLba)
                : child.dataLba
            let childBytes = child.isDirectory
                ? (joliet ? child.jolietDirectoryBytes : child.primaryDirectoryBytes)
                : Int(child.dataLength)
            add(buildDirectoryRecord(
                extentLba: childLba,
                dataLength: childBytes,
                isDirectory: child.isDirectory,
                identifier: identifierBytes(child, joliet: joliet),
                timestamp: timestamp
            ))
        }
        return extent
    }

    private static func buildDirectoryRecord(
        extentLba: Int,
        dataLength: Int,
        isDirectory: Bool,
        identifier: [UInt8],
        timestamp: Date
    ) -> [UInt8] {
        var record = [UInt8](repeating: 0, count: directoryRecordLength(identifier.count))
        record[0] = UInt8(record.count)
        writeBothEndian32(&record, 2, UInt32(extentLba))
        writeBothEndian32(&record, 10, UInt32(truncatingIfNeeded: dataLength))
        writeDirectoryDate(&record, 18, timestamp)
        record[25] = isDirectory ? 0x02 : 0x00
        writeBothEndian16(&record, 28, 1)
        record[32] = UInt8(identifier.count)
        record.replaceSubrange(33..<(33 + identifier.count), with: identifier)
        return record
    }

    // MARK: - 卷描述符

    private static func buildVolumeDescriptor(
        plan: Iso9660LayoutPlan,
        type: UInt8,
        label: String,
        joliet: Bool,
        pathTableBytes: Int,
        littlePathTableLba: Int,
        bigPathTableLba: Int,
        rootLba: Int,
        rootBytes: Int
    ) -> [UInt8] {
        var sector = [UInt8](repeating: 0, count: logicalSectorBytes)
        sector[0] = type
        writeASCII(&sector, 1, "CD001")
        sector[6] = 1
        if joliet {
            writePaddedJoliet(&sector, 8, 32, "DVDIMAGE")
            writePaddedJoliet(&sector, 40, 32, label)
            sector[88] = 0x25 // '%'
            sector[89] = 0x2F // '/'
            sector[90] = 0x45 // 'E'
        } else {
            writePaddedASCII(&sector, 8, 32, "DVDIMAGE")
            writePaddedASCII(&sector, 40, 32, label)
        }
        writeBothEndian32(&sector, 80, UInt32(plan.volumeSectors))
        writeBothEndian16(&sector, 120, 1)
        writeBothEndian16(&sector, 124, 1)
        writeBothEndian16(&sector, 128, UInt16(logicalSectorBytes))
        writeBothEndian32(&sector, 132, UInt32(pathTableBytes))
        writeUInt32(&sector, 140, UInt32(littlePathTableLba), littleEndian: true)
        writeUInt32(&sector, 148, UInt32(bigPathTableLba), littleEndian: false)
        let rootRecord = buildDirectoryRecord(
            extentLba: rootLba,
            dataLength: rootBytes,
            isDirectory: true,
            identifier: [0],
            timestamp: plan.timestamp
        )
        sector.replaceSubrange(156..<(156 + rootRecord.count), with: rootRecord)
        writeVolumeDate(&sector, 813, plan.timestamp)
        writeVolumeDate(&sector, 830, plan.timestamp)
        writeUnspecifiedVolumeDate(&sector, 847)
        writeUnspecifiedVolumeDate(&sector, 864)
        sector[881] = 1
        return sector
    }

    private static func buildTerminator() -> [UInt8] {
        var sector = [UInt8](repeating: 0, count: logicalSectorBytes)
        sector[0] = 255
        writeASCII(&sector, 1, "CD001")
        sector[6] = 1
        return sector
    }

    // MARK: - 标识符

    private static func makeUnique(
        base: String,
        used: inout Set<String>,
        suffix: String,
        maximumLength: Int
    ) -> String {
        let suffixLength = suffix.count
        var candidate = truncate(base, maximumLength - suffixLength) + suffix
        if used.insert(candidate.lowercased()).inserted {
            return candidate
        }
        for index in 2..<1_000_000 {
            let discriminator = "~\(index)"
            candidate = truncate(
                base,
                maximumLength - suffixLength - discriminator.count
            ) + discriminator + suffix
            if used.insert(candidate.lowercased()).inserted {
                return candidate
            }
        }
        return truncate(base, max(0, maximumLength - suffixLength)) + suffix
    }

    private static func truncate(_ value: String, _ maximumCharacters: Int) -> String {
        guard maximumCharacters > 0 else { return "" }
        return value.count <= maximumCharacters ? value : String(value.prefix(maximumCharacters))
    }

    private static func normalizePrimaryIdentifier(
        _ value: String,
        maximumLength: Int,
        fallback: String
    ) -> String {
        let normalized = value.precomposedStringWithCompatibilityMapping.uppercased()
        var result = ""
        for scalar in normalized.unicodeScalars {
            let isAllowed = (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 48 && scalar.value <= 57)
                || scalar == "_"
                || scalar == "."
            result.unicodeScalars.append(isAllowed ? scalar : "_")
            if result.count == maximumLength { break }
        }
        while result.hasPrefix(".") { result.removeFirst() }
        while result.hasSuffix(".") { result.removeLast() }
        return result.isEmpty ? fallback : result
    }

    private static func normalizeJolietIdentifier(
        _ value: String,
        maximumLength: Int,
        fallback: String
    ) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        var result = ""
        for scalar in normalized.unicodeScalars {
            let isAllowed = scalar.value != 0
                && scalar != "/"
                && scalar != "\\"
                && scalar != ":"
                && scalar != ";"
            result.unicodeScalars.append(isAllowed ? scalar : "_")
            if result.count == maximumLength { break }
        }
        return result.isEmpty ? fallback : result
    }

    // MARK: - 源文件校验 / 拷贝

    private static func validateSourceFile(entry: FileTreeEntry) throws {
        let url = entry.sourceURL
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw DiscError.io("数据盘里不能有符号链接：\(entry.relativePath)")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DiscError.missingPayload("文件不存在：\(entry.relativePath)")
        }
    }

    private static func validateSourceFile(_ node: Iso9660Node) throws {
        guard let url = node.sourceURL else {
            throw DiscError.missingPayload("缺少源文件：\(node.relativePath)")
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
        if values.isSymbolicLink == true {
            throw DiscError.io("数据盘里不能有符号链接：\(node.relativePath)")
        }
        guard values.isRegularFile != false else {
            throw DiscError.io("不是普通文件：\(node.relativePath)")
        }
        guard let size = values.fileSize, Int64(size) == node.dataLength else {
            throw DiscError.io("文件大小在规划后发生变化：\(node.relativePath)")
        }
    }

    private static func writeContents(of node: Iso9660Node, to sink: SequentialSink) throws {
        guard let url = node.sourceURL else {
            throw DiscError.missingPayload("缺少源文件：\(node.relativePath)")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DiscError.io("无法读取 \(node.relativePath)：\(error.localizedDescription)")
        }
        defer { try? handle.close() }

        var remaining = node.dataLength
        while remaining > 0 {
            let requested = Int(min(Int64(128 * 1024), remaining))
            let data: Data
            do {
                data = try handle.read(upToCount: requested) ?? Data()
            } catch {
                throw DiscError.io("读取 \(node.relativePath) 失败：\(error.localizedDescription)")
            }
            guard !data.isEmpty else {
                throw DiscError.io("文件提前结束：\(node.relativePath)")
            }
            try data.withUnsafeBytes { raw in
                try sink.write(raw)
            }
            remaining -= Int64(data.count)
        }
    }

    // MARK: - 小端 / 大端 / 日期

    private static func writeUInt16(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt16, littleEndian: Bool) {
        let bytes: [UInt8] = littleEndian
            ? [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
            : [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        buffer.replaceSubrange(offset..<(offset + 2), with: bytes)
    }

    private static func writeUInt32(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt32, littleEndian: Bool) {
        let bytes: [UInt8] = littleEndian
            ? [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
               UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
            : [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
               UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        buffer.replaceSubrange(offset..<(offset + 4), with: bytes)
    }

    private static func writeBothEndian16(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt16) {
        writeUInt16(&buffer, offset, value, littleEndian: true)
        writeUInt16(&buffer, offset + 2, value, littleEndian: false)
    }

    private static func writeBothEndian32(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt32) {
        writeUInt32(&buffer, offset, value, littleEndian: true)
        writeUInt32(&buffer, offset + 4, value, littleEndian: false)
    }

    private static func appendUInt16(_ buffer: inout [UInt8], _ value: UInt16, littleEndian: Bool) {
        if littleEndian {
            buffer.append(UInt8(value & 0xFF))
            buffer.append(UInt8((value >> 8) & 0xFF))
        } else {
            buffer.append(UInt8((value >> 8) & 0xFF))
            buffer.append(UInt8(value & 0xFF))
        }
    }

    private static func appendUInt32(_ buffer: inout [UInt8], _ value: UInt32, littleEndian: Bool) {
        if littleEndian {
            buffer.append(UInt8(value & 0xFF))
            buffer.append(UInt8((value >> 8) & 0xFF))
            buffer.append(UInt8((value >> 16) & 0xFF))
            buffer.append(UInt8((value >> 24) & 0xFF))
        } else {
            buffer.append(UInt8((value >> 24) & 0xFF))
            buffer.append(UInt8((value >> 16) & 0xFF))
            buffer.append(UInt8((value >> 8) & 0xFF))
            buffer.append(UInt8(value & 0xFF))
        }
    }

    private static func writeASCII(_ buffer: inout [UInt8], _ offset: Int, _ value: String) {
        let bytes = Array(value.utf8)
        buffer.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    private static func writePaddedASCII(_ buffer: inout [UInt8], _ offset: Int, _ length: Int, _ value: String) {
        for index in 0..<length {
            buffer[offset + index] = 0x20
        }
        let bytes = Array(value.utf8.prefix(length))
        buffer.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    private static func writePaddedJoliet(_ buffer: inout [UInt8], _ offset: Int, _ length: Int, _ value: String) {
        for index in stride(from: 0, to: length, by: 2) {
            buffer[offset + index] = 0
            buffer[offset + index + 1] = 0x20
        }
        let bytes = Array(utf16BigEndian(value).prefix(length))
        buffer.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    private static func utf16BigEndian(_ value: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.utf16.count * 2)
        for unit in value.utf16 {
            bytes.append(UInt8((unit >> 8) & 0xFF))
            bytes.append(UInt8(unit & 0xFF))
        }
        return bytes
    }

    private static func utcComponents(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
    }

    private static func writeDirectoryDate(_ buffer: inout [UInt8], _ offset: Int, _ date: Date) {
        let components = utcComponents(date)
        let year = min(max(components.year ?? 1970, 1900), 2155)
        buffer[offset] = UInt8(year - 1900)
        buffer[offset + 1] = UInt8(min(max(components.month ?? 1, 1), 12))
        buffer[offset + 2] = UInt8(min(max(components.day ?? 1, 1), 31))
        buffer[offset + 3] = UInt8(min(max(components.hour ?? 0, 0), 23))
        buffer[offset + 4] = UInt8(min(max(components.minute ?? 0, 0), 59))
        buffer[offset + 5] = UInt8(min(max(components.second ?? 0, 0), 59))
        buffer[offset + 6] = 0
    }

    private static func writeVolumeDate(_ buffer: inout [UInt8], _ offset: Int, _ date: Date) {
        let components = utcComponents(date)
        let year = min(max(components.year ?? 1970, 1900), 2155)
        let digits = String(
            format: "%04d%02d%02d%02d%02d%02d%02d",
            year,
            min(max(components.month ?? 1, 1), 12),
            min(max(components.day ?? 1, 1), 31),
            min(max(components.hour ?? 0, 0), 23),
            min(max(components.minute ?? 0, 0), 59),
            min(max(components.second ?? 0, 0), 59),
            min(max((components.nanosecond ?? 0) / 10_000_000, 0), 99)
        )
        let bytes = Array(digits.utf8.prefix(16))
        buffer.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        buffer[offset + 16] = 0
    }

    private static func writeUnspecifiedVolumeDate(_ buffer: inout [UInt8], _ offset: Int) {
        for index in 0..<16 {
            buffer[offset + index] = UInt8(ascii: "0")
        }
        buffer[offset + 16] = 0
    }
}

/// 只往前写的 ISO 卷写入器：按 LBA 补零后写 extent。
private struct SequentialIsoWriter {
    let sink: SequentialSink

    func writeAtLba(_ lba: Int, _ bytes: [UInt8]) throws {
        try sink.pad(to: Int64(lba) * Int64(Iso9660Writer.logicalSectorBytes), with: 0)
        try sink.write(bytes)
    }

    func pad(toLba lba: Int) throws {
        try sink.pad(to: Int64(lba) * Int64(Iso9660Writer.logicalSectorBytes), with: 0)
    }
}
