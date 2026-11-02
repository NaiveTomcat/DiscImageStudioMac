import Foundation

/// `drutil` / `hdiutil` 输出的容错解析。
///
/// 这一层是纯函数：输入是固定样本字符串，输出是结构体。这样「有设备 / 无设备 /
/// 空白盘 / 非空白盘 / 各种失败」都能在没有光驱的机器上做回归。
///
/// **重要边界**：`drutil` 的文本输出不是公开 API，不同 macOS 版本会改列宽、
/// 改措辞。下面按「先按表头列宽切、切不动再按空白切」的策略做兜底；本机没有
/// 刻录机，样本来自系统实际空输出与公开文档/论坛记录，**没有在真机上验证过**。
/// 因此 `DrutilBurner` 在解析失败时会抛出带原始输出的错误，而不是猜一个状态。
public enum DrutilParser {

    // MARK: - drutil list

    /// 解析 `drutil list` 的设备表。
    ///
    /// 关键行为：
    /// - **无设备时只有表头**（这台机器上就是这种情况）→ 返回空数组，不抛错；
    /// - 列宽可变：优先按表头里 `Vendor` / `Product` / `Rev` / `Bus` /
    ///   `SupportLevel` 的起始位置切片，这样产品名里的双空格（`BD-RE  WH16NS40`）
    ///   不会被误切；
    /// - 有些版本在行首多打印一列序号，切不动时退回按空白切分并丢掉行首数字；
    /// - `id` 取列表顺序的 1 基序号，与 `drutil -drive <n>` 完全一致。
    public static func parseDeviceList(_ output: String) -> [DiscDevice] {
        let lines = output.components(separatedBy: .newlines)
        guard let headerIndex = lines.firstIndex(where: isDeviceTableHeader) else { return [] }
        let layout = columnLayout(from: lines[headerIndex])

        var devices: [DiscDevice] = []
        for line in lines.dropFirst(headerIndex + 1) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if isDeviceTableHeader(line) { continue }
            guard let fields = deviceFields(from: line, layout: layout) else { continue }
            devices.append(
                DiscDevice(
                    id: String(devices.count + 1),
                    vendor: fields.vendor,
                    product: fields.product,
                    bus: fields.bus,
                    supportLevel: fields.supportLevel
                )
            )
        }
        return devices
    }

    static func isDeviceTableHeader(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("vendor") && lower.contains("product") && lower.contains("support")
    }

    struct ColumnLayout {
        let vendor: Int
        let product: Int
        let rev: Int?
        let bus: Int?
        let support: Int?

        /// 除 vendor 外的列起点（升序），用于切片。
        var starts: [(name: String, offset: Int)] {
            var result: [(String, Int)] = [("vendor", vendor), ("product", product)]
            if let rev { result.append(("rev", rev)) }
            if let bus { result.append(("bus", bus)) }
            if let support { result.append(("support", support)) }
            return result.sorted { $0.1 < $1.1 }
        }
    }

    static func columnLayout(from header: String) -> ColumnLayout? {
        func offset(of keyword: String) -> Int? {
            guard let range = header.range(of: keyword, options: [.caseInsensitive]) else { return nil }
            return header.distance(from: header.startIndex, to: range.lowerBound)
        }
        guard let vendor = offset(of: "Vendor"), let product = offset(of: "Product") else { return nil }
        return ColumnLayout(
            vendor: vendor,
            product: product,
            rev: offset(of: "Rev"),
            bus: offset(of: "Bus"),
            support: offset(of: "SupportLevel")
        )
    }

    struct DeviceFields {
        let vendor: String
        let product: String
        let bus: String
        let supportLevel: String
        let rev: String
    }

    static func deviceFields(from line: String, layout: ColumnLayout?) -> DeviceFields? {
        if let layout, let sliced = slice(line, layout: layout) { return sliced }
        return tokenize(line)
    }

    /// 按表头列宽切片；行首出现表头没有的内容（多见于「序号」列）时返回 nil，
    /// 交给 `tokenize` 兜底。
    static func slice(_ line: String, layout: ColumnLayout) -> DeviceFields? {
        let characters = Array(line)
        guard characters.count > layout.vendor else { return nil }
        let prefix = String(characters[0..<layout.vendor]).trimmingCharacters(in: .whitespaces)
        guard prefix.isEmpty else { return nil }

        var values: [String: String] = [:]
        let starts = layout.starts
        for (index, column) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].offset : characters.count
            guard column.offset < end, end <= characters.count else {
                values[column.name] = ""
                continue
            }
            values[column.name] = String(characters[column.offset..<end])
                .trimmingCharacters(in: .whitespaces)
        }

        let vendor = values["vendor"] ?? ""
        let support = values["support"] ?? ""
        // 切出来的东西不像设备行（空、或整列是数字）→ 让 tokenize 再试一次。
        guard !vendor.isEmpty,
              !vendor.allSatisfy(\.isNumber),
              !support.isEmpty,
              !vendor.contains("Vendor") else {
            return nil
        }
        return DeviceFields(
            vendor: vendor,
            product: values["product"] ?? "",
            bus: values["bus"] ?? "",
            supportLevel: support,
            rev: values["rev"] ?? ""
        )
    }

    /// 空白切分兜底：把 support / bus / rev 从右边数，vendor 取第一个词，
    /// 中间剩下的都算 product（产品名里经常有空格）。
    static func tokenize(_ line: String) -> DeviceFields? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        func dropLeadingIndex(_ tokens: [String]) -> [String] {
            if tokens.count >= 6, tokens[0].allSatisfy(\.isNumber) {
                return Array(tokens.dropFirst())
            }
            return tokens
        }

        var tokens = dropLeadingIndex(
            trimmed.components(separatedBy: "  ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        if tokens.count >= 5 {
            let support = tokens[tokens.count - 1]
            let bus = tokens[tokens.count - 2]
            let rev = tokens[tokens.count - 3]
            let product = tokens[1..<(tokens.count - 3)].joined(separator: " ")
            return DeviceFields(vendor: tokens[0], product: product, bus: bus, supportLevel: support, rev: rev)
        }
        if tokens.count == 4 {
            return DeviceFields(vendor: tokens[0], product: tokens[1], bus: tokens[2], supportLevel: tokens[3], rev: "")
        }

        tokens = dropLeadingIndex(trimmed.split(separator: " ").map(String.init))
        guard tokens.count >= 4 else { return nil }
        let support = tokens[tokens.count - 1]
        let bus = tokens[tokens.count - 2]
        let rev = tokens.count >= 5 ? tokens[tokens.count - 3] : ""
        let productEnd = max(1, tokens.count - 3)
        let product = productEnd > 1 ? tokens[1..<productEnd].joined(separator: " ") : ""
        return DeviceFields(vendor: tokens[0], product: product, bus: bus, supportLevel: support, rev: rev)
    }

    // MARK: - drutil status

    /// 解析 `drutil status`。
    ///
    /// 已知输出形态（公开文档与论坛记录）：
    /// ```
    ///  Vendor   Product           Rev
    ///  SONY     DVD RW DRU-840A   SS00
    ///
    /// Type: DVD+R DL
    /// Name: /dev/disk4
    /// Write Speeds: 4x, 6x, 8x
    /// Space Free:  927:30:74   blocks:  4173824 /   8.55GB /   7.96GiB
    /// Space Used:   00:00:00   blocks:        0 /   0.00MB /   0.00MiB
    /// Writability: appendable, blank, overwritable
    /// ```
    /// 注意 `Space Free:` 的值可能折到下一行，所以「本行没有数字就看下一行」。
    public static func parseStatus(_ output: String) throws -> DiscStatus {
        let raw = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            // 没有刻录机时 `drutil status` 输出为空、退出码 0。
            throw BurnError.noDevice
        }
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw BurnError.noDevice }

        var mediaType = ""
        var writability: [String] = []
        var freeBytes: Int64?
        var usedBytes: Int64?
        var sawField = false

        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            if lower.hasPrefix("type:") {
                mediaType = value(afterColonIn: line)
                sawField = true
            } else if lower.hasPrefix("writability:") {
                writability = value(afterColonIn: line)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty }
                sawField = true
            } else if lower.hasPrefix("space free:") {
                freeBytes = parseByteCount(line) ?? parseByteCount(lineAfter(index, in: lines))
                sawField = true
            } else if lower.hasPrefix("space used:") {
                usedBytes = parseByteCount(line) ?? parseByteCount(lineAfter(index, in: lines))
                sawField = true
            }
        }

        let lowerType = mediaType.lowercased()
        if lowerType.contains("no media") || lowerType.contains("no disc") {
            throw BurnError.noMedia(device: nil)
        }
        guard sawField || !mediaType.isEmpty else {
            throw BurnError.unparsableStatus(raw)
        }

        let isBlank = writability.contains { $0.contains("blank") }
        let hasRoom = isBlank || writability.contains {
            $0.contains("appendable") || $0.contains("overwritable") || $0.contains("recordable") || $0.contains("writable")
        }
        // 只读介质的类型名里带 rom（但 DVD-RAM 是可写的，要排除）。
        let isReadOnly = lowerType.contains("rom") && !lowerType.contains("ram")
        let isRecordableType = !isReadOnly && ["cd-r", "cd-rw", "dvd-r", "dvd+r", "dvd-rw",
                                               "dvd+rw", "dvd-ram", "bd-r", "bd-re"]
            .contains { lowerType.contains($0) }
        let isWritable = isRecordableType && hasRoom

        let free = freeBytes ?? 0
        let used = usedBytes ?? 0
        let capacity = max(free + used, max(free, used))
        return DiscStatus(
            isBlank: isBlank,
            mediaType: mediaType,
            capacityBytes: capacity,
            freeBytes: free,
            isWritable: isWritable
        )
    }

    static func value(afterColonIn line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    static func lineAfter(_ index: Int, in lines: [String]) -> String {
        index + 1 < lines.count ? lines[index + 1] : ""
    }

    /// 从一行里抠字节数。优先 `blocks:`（每块 2048 字节，DVD/BD 的 2048 字节扇区），
    /// 其次 `8.55GB` / `702.82MiB` 这类人类可读单位。
    static func parseByteCount(_ text: String) -> Int64? {
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "blocks:", options: .caseInsensitive) {
            var digits = ""
            for character in text[range.upperBound...] {
                if character.isNumber {
                    digits.append(character)
                } else if character == "," {
                    continue
                } else if character == " " {
                    if digits.isEmpty { continue } else { break }
                } else {
                    break
                }
            }
            if let blocks = Int64(digits) { return blocks * 2048 }
        }
        return humanByteCount(in: text)
    }

    static func humanByteCount(in text: String) -> Int64? {
        let multipliers: [String: Double] = [
            "B": 1, "KB": 1_000, "MB": 1_000_000, "GB": 1_000_000_000, "TB": 1e12,
            "KIB": 1_024, "MIB": 1_048_576, "GIB": 1_073_741_824, "TIB": 1_099_511_627_776,
        ]
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            var number = ""
            var cursor = index
            while cursor < characters.count, characters[cursor].isNumber || characters[cursor] == "." {
                number.append(characters[cursor])
                cursor += 1
            }
            if !number.isEmpty, let value = Double(number) {
                var unitCursor = cursor
                while unitCursor < characters.count, characters[unitCursor] == " " { unitCursor += 1 }
                var unit = ""
                while unitCursor < characters.count, characters[unitCursor].isLetter {
                    unit.append(characters[unitCursor])
                    unitCursor += 1
                }
                if let multiplier = multipliers[unit.uppercased()] {
                    return Int64((value * multiplier).rounded())
                }
            }
            index = max(cursor, index + 1)
        }
        return nil
    }

    // MARK: - 进度

    /// 从一行输出里解析刻录进度。解析不出任何线索时返回 nil（当作噪音忽略）。
    ///
    /// 容错点：只认「百分比」和「阶段关键字」，不依赖固定格式；`verifying` /
    /// `finalizing` 这类词按优先级判断，避免 "verify 42%" 被当成写盘。
    public static func parseProgress(_ line: String) -> BurnProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let fraction = percentage(in: trimmed)

        // 顺序有讲究：「Burning: 42% complete」既有 burn 又有 complete，有百分比时
        // 必须以写盘为准；只有「Done / Finalizing」这种没有动词和数字的行才算收尾。
        var stage: BurnProgress.Stage?
        if lower.contains("fail") || lower.contains("error") || lower.contains("could not") {
            stage = .failed
        } else if lower.contains("verif") {
            stage = .verifying
        } else if lower.contains("prepar") || lower.contains("warm") {
            stage = .preparing
        } else if lower.contains("burn") || lower.contains("writ") {
            stage = .writing
        } else if lower.contains("finaliz") || lower.contains("closing") || lower.contains("closed")
                    || lower.contains("done") || lower.contains("complet") || lower.contains("finish") {
            stage = .finishing
        } else if fraction != nil {
            stage = .writing
        }

        guard stage != nil || fraction != nil else { return nil }
        return BurnProgress(stage: stage ?? .writing, fraction: fraction, rawLine: trimmed)
    }

    /// 取出第一个 `NN%` / `NN.N %`。范围外的（>100）当作没解析到。
    static func percentage(in text: String) -> Double? {
        let characters = Array(text)
        for (index, character) in characters.enumerated() where character == "%" {
            var cursor = index - 1
            while cursor >= 0, characters[cursor] == " " { cursor -= 1 }
            var number = ""
            while cursor >= 0, characters[cursor].isNumber || characters[cursor] == "." {
                number.insert(characters[cursor], at: number.startIndex)
                cursor -= 1
            }
            if let value = Double(number), value >= 0, value <= 100 {
                return value / 100.0
            }
        }
        return nil
    }

    // MARK: - 失败分类

    /// 把「退出码 + 输出」翻译成可执行的中文错误。
    ///
    /// 顺序有意义：先认设备/介质级问题（能给出「放盘/换盘」这种明确动作），
    /// 再认权限/占用，最后才落到通用的 `toolFailed`。
    public static func failure(for result: CommandResult, command: BurnCommand) -> BurnError {
        let text = result.combinedOutput.lowercased()
        let mediaType = mediaType(in: result.combinedOutput)

        if text.contains("could not find a valid device")
            || text.contains("no burning device")
            || text.contains("no drives found")
            || text.contains("no device found") {
            return .noDevice
        }
        if text.contains("no media inserted") || text.contains("please insert")
            || text.contains("no media") || text.contains("no disc") {
            return .noMedia(device: nil)
        }
        if text.contains("permission denied") || text.contains("operation not permitted")
            || text.contains("not authorized") || text.contains("authorization")
            || text.contains("could not acquire") {
            return .permissionDenied(firstLine(of: result.combinedOutput))
        }
        if text.contains("is busy") || text.contains("in use") || text.contains("exclusive access") {
            return .deviceBusy(firstLine(of: result.combinedOutput))
        }
        if text.contains("not blank") || text.contains("not appendable")
            || text.contains("medium is not") {
            return .discNotBlank(mediaType: mediaType.isEmpty ? "未知介质" : mediaType)
        }
        if text.contains("not enough space") || text.contains("insufficient")
            || text.contains("does not fit") || text.contains("won't fit")
            || text.contains("too large") || text.contains("exceeds") {
            return .insufficientCapacity(requiredBytes: 0, availableBytes: 0)
        }
        return .toolFailed(
            command: command.displayString,
            exitCode: result.exitCode,
            output: outputTail(result.combinedOutput)
        )
    }

    static func mediaType(in output: String) -> String {
        for line in output.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("type:") {
                let value = self.value(afterColonIn: line)
                if !value.isEmpty { return value }
            }
        }
        return ""
    }

    static func firstLine(of output: String) -> String {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// 错误对话框里只放最后几行：drutil 的废话很多，全文会撑爆弹窗。
    static func outputTail(_ output: String, maxLines: Int = 3, maxLength: Int = 400) -> String {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = lines.suffix(maxLines).joined(separator: " / ")
        return tail.count > maxLength ? String(tail.prefix(maxLength)) + "…" : tail
    }
}
