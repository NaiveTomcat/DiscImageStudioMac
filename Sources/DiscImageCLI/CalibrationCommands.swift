import DiscImageCore
import Foundation

/// 标定相关子命令。
///
/// 完整闭环在 GUI 里是「生成图案 → 烧盘 → 拍照 → 拖边界 → 点曲线 → 反推 → 应用」，
/// 但其中三步（生成图案、反推、导出会话）不依赖 UI，所以也放进 CLI——
/// 这样没有图形环境也能做回归，也方便把标定结果接到脚本里。
///
/// ```bash
/// discimage-cli calibration pattern --family dvd --preset dvd-5-120mm --out artifacts/cal
/// discimage-cli calibration fit --session artifacts/cal/calibration.calibration.json \
///     --trace "26.0,0;30.0,0.7;36.0,1.2;44.0,2.0;52.0,2.7"
/// ```

func runCalibration(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
        throw DiscError.unsupported("用法：calibration pattern|fit …")
    }
    let rest = Array(arguments.dropFirst())
    switch subcommand {
    case "pattern":
        try runCalibrationPattern(rest)
    case "fit":
        try runCalibrationFit(rest)
    default:
        throw DiscError.unsupported("未知标定子命令：\(subcommand)（可用 pattern / fit）")
    }
}

private func runCalibrationPattern(_ arguments: [String]) throws {
    let parser = try ArgumentParser(arguments: arguments, valueOptions: valueOptions + ["out", "name"], flags: ["prerelease"])
    let familyToken = try parser.requiredString("family")
    guard let family = DiscFamily.fromProjectToken(familyToken) else {
        throw DiscError.unsupported("未知介质：\(familyToken)")
    }
    let geometry = try makeGeometry(family: family, parser: parser)
    try geometry.validate()
    let tone = makeTone(parser: parser, family: family)

    let directory = URL(fileURLWithPath: ((parser.string("out") ?? ".") as NSString).expandingTildeInPath)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let baseName = parser.string("name") ?? "calibration"
    let pngURL = directory.appendingPathComponent("\(baseName)-pattern.png")
    let sessionURL = directory.appendingPathComponent("\(baseName).calibration.json")

    try CalibrationPattern.writePNG(to: pngURL, geometry: geometry)

    let snapshot = CalibrationGenerationSnapshot(
        geometry: geometry,
        tone: tone,
        drawingStartSector: 0,
        drawingEndSectorExclusive: 0,
        cdInterleave: family == .cd
    )
    let session = CalibrationSession(generation: snapshot)
    try CalibrationSessionStore.save(session, to: sessionURL)

    print("标定图案：\(pngURL.path)")
    print("会话文件：\(sessionURL.path)")
    print(String(format: "几何：%.3f–%.3f mm，%d 扇区，图案按外半径 %.3f mm 缩放",
                 geometry.innerRadiusMm, geometry.outerRadiusMm, geometry.sectors,
                 snapshot.patternScaleMm))
    print("下一步：用这张图案生成并烧录标定盘 → 拍照 → 在 GUI 标定页拖边界、点曲线、反推")
}

private func runCalibrationFit(_ arguments: [String]) throws {
    let parser = try ArgumentParser(arguments: arguments, valueOptions: ["session", "trace", "max-candidates"], flags: ["json"])
    let sessionURL = URL(fileURLWithPath: (try parser.requiredString("session") as NSString).expandingTildeInPath)
    let session = try CalibrationSessionStore.load(from: sessionURL)

    let points: [CalibrationPoint]
    if let raw = parser.string("trace") {
        points = try parseCalibrationPoints(raw)
    } else if let trace = session.trace, !trace.points.isEmpty {
        points = trace.points
    } else {
        throw DiscError.missingPayload("会话里没有曲线点；用 --trace \"x,y;x,y;...\" 提供（单位 mm，盘心为原点）")
    }

    var options = CalibrationFitOptions.`default`
    if let maxCandidates = parser.int("max-candidates") {
        options.maxCandidates = max(1, maxCandidates)
    }

    let result = try CalibrationCrossFitter.fit(session: session, points: points, options: options)

    if parser.bool("json") {
        printFitResultJSON(result)
        return
    }

    print("输入曲线点：\(points.count) 个")
    if let range = result.searchRangeMm {
        print(String(format: "搜索范围：±%.4f mm%@", range.1,
                     result.boundaryLimited ? "（最优解落在边界上，结果不可信）" : ""))
    }
    for (index, candidate) in result.candidates.enumerated() {
        let mark = index == 0 ? "★" : " "
        print(String(format: "%@ 候选 %d：内 %.4f / 外 %.4f mm，转角 %.4f rad，rms %.4f mm，最大 %.4f mm，离群 %d%@",
                     mark, index + 1,
                     candidate.innerRadiusMm, candidate.outerRadiusMm, candidate.rotationRadians,
                     candidate.rmsErrorMm, candidate.maxErrorMm, candidate.outlierCount,
                     candidate.isApplicable ? "" : "（不可应用）"))
        if candidate.hasCubicPitch {
            print(String(format: "     三次轨距：c1=%.6g c2=%.6g c3=%.6g",
                         candidate.pitchLinear, candidate.pitchQuadratic, candidate.pitchCubic))
        }
    }
    if let best = result.best {
        print("最佳候选可应用：\(best.isApplicable ? "是" : "否")")
        let updated = best.applying(to: session.generation.geometry)
        print(String(format: "应用后几何：内 %.6f mm、外 %.6f mm、三次系数（c1 %.6g / c2 %.6g / c3 %.6g）",
                     updated.innerRadiusMm, updated.outerRadiusMm,
                     updated.pitchLinear, updated.pitchQuadratic, updated.pitchCubic))
    }
    for warning in result.warnings {
        print("警告：\(warning)")
    }
    if let reason = result.rejectionReason {
        print("拒绝原因：\(reason)")
    }
}

private func parseCalibrationPoints(_ raw: String) throws -> [CalibrationPoint] {
    var points: [CalibrationPoint] = []
    for chunk in raw.split(separator: ";") {
        let trimmed = chunk.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        let parts = trimmed.split(separator: ",")
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) else {
            throw DiscError.unsupported("曲线点格式错误：\(trimmed)（应为 \"x,y\"，单位 mm）")
        }
        points.append(CalibrationPoint(xMm: x, yMm: y))
    }
    guard !points.isEmpty else {
        throw DiscError.missingPayload("没有解析到任何曲线点")
    }
    return points
}

private func printFitResultJSON(_ result: CalibrationFitResult) {
    func number(_ value: Double) -> String {
        String(format: "%.8f", value)
    }
    var lines: [String] = []
    lines.append("{")
    lines.append("  \"succeeded\": \(result.succeeded),")
    lines.append("  \"applicable\": \(result.isApplicable),")
    lines.append("  \"rmsErrorMm\": \(number(result.rmsErrorMm)),")
    if let range = result.searchRangeMm {
        lines.append("  \"searchRangeMm\": [\(number(range.0)), \(number(range.1))],")
    }
    lines.append("  \"boundaryLimited\": \(result.boundaryLimited),")
    let candidates = result.candidates.map { candidate -> String in
        """
            {
              "innerRadiusMm": \(number(candidate.innerRadiusMm)),
              "outerRadiusMm": \(number(candidate.outerRadiusMm)),
              "rotationRadians": \(number(candidate.rotationRadians)),
              "pitchLinear": \(number(candidate.pitchLinear)),
              "pitchQuadratic": \(number(candidate.pitchQuadratic)),
              "pitchCubic": \(number(candidate.pitchCubic)),
              "rmsErrorMm": \(number(candidate.rmsErrorMm)),
              "maxErrorMm": \(number(candidate.maxErrorMm)),
              "outlierCount": \(candidate.outlierCount),
              "applicable": \(candidate.isApplicable)
            }
        """
    }
    lines.append("  \"candidates\": [")
    lines.append(candidates.joined(separator: ",\n"))
    lines.append("  ]")
    lines.append("}")
    print(lines.joined(separator: "\n"))
}
