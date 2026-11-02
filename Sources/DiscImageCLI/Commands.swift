import DiscImageCore
import Foundation

let valueOptions = [
    "family", "image", "out", "format", "preset",
    "inner", "outer", "sectors", "velocity", "bit-length",
    "dither", "levels", "brightness", "data-dir", "label", "size",
]
let flagOptions = ["srgb", "outer-ring", "quiet"]

func runGenerate(_ arguments: [String]) throws {
    let parser = try ArgumentParser(arguments: arguments, valueOptions: valueOptions, flags: flagOptions)

    let familyToken = try parser.requiredString("family")
    guard let family = DiscFamily.fromProjectToken(familyToken) else {
        throw DiscError.unsupported("未知介质：\(familyToken)（可选 cd / dvd / bd）")
    }

    let geometry = try makeGeometry(family: family, parser: parser)
    try geometry.validate()

    let tone = makeTone(parser: parser, family: family)
    try tone.validate()

    let format: GenerationOutputFormat
    if let raw = parser.string("format") {
        guard let parsed = GenerationOutputFormat(rawValue: raw), GenerationOutputFormat.options(for: family).contains(parsed) else {
            throw DiscError.unsupported("\(family.displayNameZH) 不支持输出格式：\(raw)")
        }
        format = parsed
    } else {
        format = family == .cd ? .iso : .iso
    }

    let image = try loadImage(parser: parser)
    let dataDirectory = parser.string("data-dir").map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
    }
    if format == .iso, family == .cd, dataDirectory == nil {
        // CD 的 ISO 输出只在数据盘模式有意义
        throw DiscError.unsupported("CD 的 ISO 输出需要 --data-dir（数据盘模式）；纯绘图请用 wav 或 raw")
    }

    let outputURL = URL(fileURLWithPath: (try parser.requiredString("out") as NSString).expandingTildeInPath)
    let baseURL = outputURL.deletingPathExtension()
    let volumeLabel = parser.string("label") ?? "DISC_IMAGE"

    let request = GenerationRequest(
        geometry: geometry,
        tone: tone,
        image: image,
        outputFormat: format,
        dataDirectory: dataDirectory,
        dataAtOuterRing: parser.bool("outer-ring"),
        volumeLabel: volumeLabel,
        clockwise: family == .dvd,
        outputBaseURL: baseURL
    )

    let generator = try generator(for: family)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let quiet = parser.bool("quiet")
    let sink = try FileSequentialSink(url: outputURL)
    let started = Date()
    let result = try generator.generate(request, to: sink) { progress in
        guard !quiet else { return }
        let percent = progress.fraction.map { String(format: "%5.1f%%", $0 * 100) } ?? "  --- "
        FileHandle.standardError.write(Data("[\(percent)] \(progress.stage)：\(progress.message)\n".utf8))
    }
    try sink.close()

    let elapsed = Date().timeIntervalSince(started)
    let megabyte = Double(result.byteCount) / 1_048_576.0
    print("完成：\(result.summary)")
    print("输出：\(outputURL.path)")
    print(String(format: "大小：%.2f MiB，耗时 %.2f s", megabyte, elapsed))
    for sidecar in result.sidecarURLs {
        print("旁写：\(sidecar.path)")
    }
}

func makeGeometry(family: DiscFamily, parser: ArgumentParser) throws -> DiscGeometry {
    if let presetID = parser.string("preset") {
        guard let preset = DiscPreset.preset(id: presetID) else {
            throw DiscError.unsupported("未知预设：\(presetID)")
        }
        guard preset.family == family else {
            throw DiscError.unsupported("预设 \(presetID) 属于 \(preset.family.displayNameZH)，与 --family 不符")
        }
        return preset.geometry()
    }

    let inner = parser.double("inner")
    let outer = parser.double("outer")
    let sectors = parser.int("sectors")
    guard let inner, let outer, let sectors else {
        throw DiscError.unsupported("需要 --preset，或同时给出 --inner / --outer / --sectors")
    }

    var geometry = DiscPreset.defaultPreset(for: family).geometry()
    geometry.family = family
    geometry.innerRadiusMm = inner
    geometry.outerRadiusMm = outer
    geometry.sectors = sectors
    if let velocity = parser.double("velocity") { geometry.linearVelocityMmPerSecond = velocity }
    if let bitLength = parser.double("bit-length") { geometry.channelBitLengthNm = bitLength }
    return geometry
}

func makeTone(parser: ArgumentParser, family: DiscFamily) -> ToneProfile {
    var tone = ToneProfile.default
    if let dither = parser.double("dither") {
        tone.ditherStrength = dither / 100.0
    }
    if let levels = parser.int("levels") {
        tone.levels = levels
    }
    if let brightness = parser.int("brightness") {
        tone.brightness = brightness
    }
    if parser.bool("srgb") {
        tone.srgbLinearization = 1
    }
    if family != .cd {
        tone.levels = 2
    }
    return tone.normalized()
}

func loadImage(parser: ArgumentParser) throws -> RasterImage {
    if let path = parser.string("image") {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return try RasterImage.load(contentsOf: url)
    }
    let size = max(64, parser.int("size") ?? 2048)
    return .black(width: size, height: size)
}

func runPresets(_ arguments: [String]) {
    let parser = try? ArgumentParser(arguments: arguments, valueOptions: ["family"], flags: [])
    let families: [DiscFamily]
    if let token = parser?.string("family"), let family = DiscFamily.fromProjectToken(token) {
        families = [family]
    } else {
        families = DiscFamily.allCases
    }
    for family in families {
        print("== \(family.displayNameZH) ==")
        for preset in DiscPreset.presets(for: family) {
            let pitch = String(format: "%.4f µm", preset.pitchMicrometres)
            print(String(format: "  %-32@ %12ld 扇区  %.3f–%.3f mm  螺距 %@%@",
                         preset.id as NSString,
                         preset.sectors,
                         preset.innerRadiusMm,
                         preset.outerRadiusMm,
                         pitch as NSString,
                         preset.isMeasured ? "  [实测]" : ""))
        }
    }
}

func runGeometry(_ arguments: [String]) throws {
    let parser = try ArgumentParser(arguments: arguments, valueOptions: valueOptions, flags: [])
    let familyToken = try parser.requiredString("family")
    guard let family = DiscFamily.fromProjectToken(familyToken) else {
        throw DiscError.unsupported("未知介质：\(familyToken)")
    }
    let geometry = try makeGeometry(family: family, parser: parser)
    try geometry.validate()
    let spiral = geometry.spiral
    print("介质：\(family.displayNameZH)")
    print(String(format: "半径：%.6f – %.6f mm", geometry.innerRadiusMm, geometry.outerRadiusMm))
    print("扇区：\(geometry.sectors)")
    print(String(format: "总长：%.3f mm（%.3f m）", geometry.totalLengthMm, geometry.totalLengthMm / 1000))
    print(String(format: "螺距：%.6f mm（%.4f µm）", spiral.pitchMm, spiral.pitchMm * 1000))
    print(String(format: "圈数：%.3f", spiral.totalTurns))
    print(String(format: "每圈扇区：%.3f", spiral.sectorsPerTurn))
    if geometry.hasCubicPitch {
        print(String(format: "三次轨距：c1=%.6g c2=%.6g c3=%.6g",
                     geometry.pitchLinear, geometry.pitchQuadratic, geometry.pitchCubic))
    }
}

func printInfo() {
    print("Disc Image Studio（macOS）命令行")
    print("DiscImageCore 版本：\(DiscImageCore.version)")
    print("介质：CD / DVD / 蓝光")
    print("刻录封装：drutil / hdiutil")
}
