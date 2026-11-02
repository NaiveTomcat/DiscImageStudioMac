import DiscImageCore
import DiscImageUI
import XCTest

/// `.discproj` 工程文件：schemaVersion 2、camelCase、读写与旧版兼容。
final class ProjectFileTests: XCTestCase {
    private let store = ProjectStore()

    // MARK: - 基本读写

    func testRoundTripKeepsAllFields() throws {
        let layer = DesignLayer(
            id: "layer-1",
            name: "图案",
            imagePath: "/tmp/pattern.png",
            visible: true,
            translateXMm: 3.5,
            translateYMm: -2.25,
            rotationDeg: 17,
            scale: 1.4
        )
        var project = DiscProject.makeNew(name: "蓝光演示", preset: .bdRsl25gb)
        project.layers = [layer]
        project.outputs.volumeLabel = "BLUE_WHALE"
        project.outputs.dataDirectory = "/tmp/data"
        project.outputs.filesAtOuterRing = true
        project.calibrationSessionPath = "/tmp/calibration"
        project.thumbnailPngBase64 = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        project.tone = ToneProfile(ditherStrength: 0.6, levels: 2, brightness: -12, srgbLinearization: 0.25)
        project.bluRay = BluRaySettings(invertMapping: true)

        let data = try store.encode(project)
        let decoded = try store.decode(data)

        XCTAssertEqual(decoded.schemaVersion, DiscProject.currentSchemaVersion)
        XCTAssertEqual(decoded.name, project.name)
        XCTAssertEqual(decoded.discFamily, .bluRay)
        XCTAssertEqual(decoded.geometry, project.geometry)
        XCTAssertEqual(decoded.layers, project.layers)
        XCTAssertEqual(decoded.outputs, project.outputs)
        XCTAssertEqual(decoded.calibrationSessionPath, "/tmp/calibration")
        XCTAssertEqual(decoded.thumbnailPngBase64, project.thumbnailPngBase64)
        XCTAssertEqual(decoded.tone, project.tone)
        XCTAssertEqual(decoded.bluRay?.invertMapping, true)
        XCTAssertEqual(decoded.createdUtc.timeIntervalSince1970,
                       project.createdUtc.timeIntervalSince1970, accuracy: 0.002)
    }

    func testJSONUsesCamelCaseAndExpectedKeys() throws {
        var project = UITestSupport.sampleProject(family: .cd)
        project.layers = [DesignLayer(name: "a", imagePath: "/tmp/a.png")]
        let data = try store.encode(project)
        let object = try JSONSerialization.jsonObject(with: data)
        let root = try XCTUnwrap(object as? [String: Any])

        for key in [
            "schemaVersion", "name", "discFamily", "geometry", "layers", "outputs",
            "createdUtc", "modifiedUtc", "tone",
        ] {
            XCTAssertNotNil(root[key], "工程 JSON 缺少字段 \(key)")
        }
        // 必须是 camelCase，不能出现 snake_case（源项目与 HANDOFF 的约定）。
        XCTAssertNil(root["schema_version"])
        XCTAssertNil(root["disc_family"])

        let geometry = try XCTUnwrap(root["geometry"] as? [String: Any])
        XCTAssertNotNil(geometry["innerRadiusMm"])
        XCTAssertNotNil(geometry["channelBitLengthNm"])

        let tone = try XCTUnwrap(root["tone"] as? [String: Any])
        XCTAssertNotNil(tone["srgbLinearization"])
        XCTAssertNotNil(tone["ditherStrength"])

        // 蓝光工程必须带 bluRay 字段。
        var bluRayProject = UITestSupport.sampleProject(family: .bluRay)
        bluRayProject.bluRay = BluRaySettings(invertMapping: false)
        let bluRayData = try store.encode(bluRayProject)
        let bluRayRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bluRayData) as? [String: Any]
        )
        XCTAssertNotNil(bluRayRoot["bluRay"])
        XCTAssertEqual(bluRayRoot["discFamily"] as? String, "bd")
    }

    func testSaveAndLoadFile() throws {
        let directory = try UITestSupport.makeTempDirectory("project-save")
        defer { UITestSupport.removeQuietly(directory) }

        var project = UITestSupport.sampleProject(family: .dvd)
        project.name = "保存测试"
        project.layers = [DesignLayer(name: "图案", imagePath: "/tmp/pattern.png")]
        let url = directory.appendingPathComponent("保存测试.discproj")

        let saved = try store.save(project, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(saved.schemaVersion, DiscProject.currentSchemaVersion)

        let loaded = try store.load(from: url)
        XCTAssertEqual(loaded.name, "保存测试")
        XCTAssertEqual(loaded.discFamily, .dvd)
        XCTAssertEqual(loaded.geometry, project.geometry)
        XCTAssertEqual(loaded.layers.count, 1)
        XCTAssertEqual(loaded.layers[0].name, "图案")
        XCTAssertEqual(loaded.modifiedUtc.timeIntervalSince1970,
                       saved.modifiedUtc.timeIntervalSince1970, accuracy: 0.002)

        // 重新保存一次不应残留临时文件。
        _ = try store.save(loaded, to: url)
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(contents.contains { $0.hasSuffix(".tmp") }, "不应残留临时文件：\(contents)")
    }

    func testLoadMissingFileThrowsChineseError() {
        let url = URL(fileURLWithPath: "/tmp/不存在的工程-\(UUID().uuidString).discproj")
        XCTAssertThrowsError(try store.load(from: url)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            XCTAssertTrue(message.contains("工程") || message.contains("读取"))
        }
    }

    // MARK: - 旧版兼容

    /// schemaVersion 1：只有 CD/DVD，geometry 没有 family，缺 tone / bluRay /
    /// calibrationSessionPath / thumbnailPngBase64，日期是 .NET 的 7 位小数。
    func testLegacySchema1WithoutNewFields() throws {
        let json = """
        {
          "schemaVersion": 1,
          "name": "旧 DVD 工程",
          "discFamily": "dvd",
          "geometry": {
            "innerRadiusMm": 24.0,
            "outerRadiusMm": 58.0,
            "sectors": 2295104,
            "pitchLinear": 0.0,
            "pitchQuadratic": 0.0,
            "pitchCubic": 0.0
          },
          "layers": [
            {
              "id": "old-layer",
              "name": "旧图层",
              "imagePath": "/tmp/old.png",
              "visible": true,
              "translateXMm": 1.0,
              "translateYMm": 2.0,
              "rotationDeg": 5.0,
              "scale": 0.8
            }
          ],
          "outputs": {
            "outputPath": "/tmp/old.iso",
            "writeCue": true,
            "dataDirectory": "",
            "volumeLabel": "OLD",
            "interleave": true
          },
          "createdUtc": "2025-01-02T03:04:05.1234567+00:00",
          "modifiedUtc": "2025-01-02T04:05:06.0000000+00:00"
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let project = try store.decode(data, sourceName: "旧工程.discproj")

        XCTAssertEqual(project.schemaVersion, 1)
        XCTAssertEqual(project.discFamily, .dvd)
        XCTAssertEqual(project.geometry.family, .dvd, "旧 geometry 没有 family，应回退到工程根的 discFamily")
        XCTAssertEqual(project.geometry.sectors, 2_295_104)
        XCTAssertEqual(project.geometry.channelBitLengthNm, 133.3, accuracy: 0.0001)
        XCTAssertEqual(project.geometry.linearVelocityMmPerSecond, 1200, accuracy: 0.0001)
        XCTAssertNil(project.tone)
        XCTAssertNil(project.bluRay)
        XCTAssertNil(project.calibrationSessionPath)
        XCTAssertNil(project.thumbnailPngBase64)
        XCTAssertEqual(project.outputs.filesAtOuterRing, false, "缺字段应补默认值")
        XCTAssertEqual(project.outputs.volumeLabel, "OLD")
        XCTAssertEqual(project.layers.count, 1)
        XCTAssertEqual(project.layers[0].rotationDeg, 5, accuracy: 1e-9)

        // 7 位小数日期应被接受（截断到毫秒）。
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: project.createdUtc
        )
        XCTAssertEqual(components.year, 2025)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 2)
        XCTAssertEqual(components.hour, 3)
        XCTAssertEqual(components.minute, 4)

        // 保存时自动升级到 schema 2，并补齐 tone。
        let upgraded = try store.encode(project)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: upgraded) as? [String: Any])
        XCTAssertEqual(root["schemaVersion"] as? Int, 2)
        XCTAssertNil(root["tone"], "旧工程没有 tone 时不应凭空写入影调")
    }

    func testLegacySchema1RejectsBluRay() throws {
        let json = """
        {
          "schemaVersion": 1,
          "name": "非法蓝光",
          "discFamily": "bd",
          "geometry": {"innerRadiusMm": 24, "outerRadiusMm": 58, "sectors": 12219392},
          "layers": [],
          "outputs": {"outputPath": "/tmp/x.iso"},
          "createdUtc": "2025-01-02T03:04:05Z",
          "modifiedUtc": "2025-01-02T03:04:05Z"
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertThrowsError(try store.decode(data)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("schemaVersion 1"), message)
        }
    }

    func testMissingTimestampsGetDefaults() throws {
        let json = """
        {
          "schemaVersion": 2,
          "name": "没有时间戳",
          "discFamily": "cd",
          "geometry": {"innerRadiusMm": 24.5, "outerRadiusMm": 56.8, "sectors": 359849},
          "layers": [],
          "outputs": {"outputPath": "/tmp/x.wav"}
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let project = try store.decode(data)
        XCTAssertLessThanOrEqual(abs(project.createdUtc.timeIntervalSinceNow), 5)
        XCTAssertLessThanOrEqual(abs(project.modifiedUtc.timeIntervalSinceNow), 5)
        XCTAssertEqual(project.createdUtc.timeIntervalSince1970,
                       project.modifiedUtc.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - 校验

    func testValidationRejectsBadDocuments() throws {
        var project = UITestSupport.sampleProject(family: .dvd)

        project.name = "   "
        XCTAssertThrowsError(try project.validate())

        project = UITestSupport.sampleProject(family: .dvd)
        project.geometry.family = .cd
        XCTAssertThrowsError(try project.validate(), "discFamily 与 geometry.family 不一致应拒绝")

        project = UITestSupport.sampleProject(family: .dvd)
        project.tone = ToneProfile(levels: 4)
        XCTAssertThrowsError(try project.validate(), "DVD 不支持 4 阶")

        project = UITestSupport.sampleProject(family: .cd)
        project.tone = ToneProfile(levels: 4)
        XCTAssertNoThrow(try project.validate(), "CD 支持 4 阶")

        project = UITestSupport.sampleProject(family: .dvd)
        project.geometry.sectors = 2_295_105
        XCTAssertThrowsError(try project.validate(), "DVD 扇区必须 %16")

        project = UITestSupport.sampleProject(family: .dvd)
        project.layers = [
            DesignLayer(id: "dup", name: "a", imagePath: "/tmp/a.png"),
            DesignLayer(id: "dup", name: "b", imagePath: "/tmp/b.png"),
        ]
        XCTAssertThrowsError(try project.validate(), "图层 id 必须唯一")

        project = UITestSupport.sampleProject(family: .cd)
        project.layers = [DesignLayer(name: "a", imagePath: "/tmp/a.png", scale: 0)]
        XCTAssertThrowsError(try project.validate(), "scale 必须大于 0")

        project = UITestSupport.sampleProject(family: .cd)
        project.thumbnailPngBase64 = String(repeating: "A", count: DiscProject.maxThumbnailBase64Length + 1)
        XCTAssertThrowsError(try project.validate(), "缩略图 base64 超长应拒绝")

        project = UITestSupport.sampleProject(family: .bluRay)
        project.bluRay = nil
        project.geometry.invertMapping = false
        XCTAssertNoThrow(try project.validate(), "蓝光工程可以不写 bluRay 字段")
    }

    func testNewProjectDefaults() throws {
        for family in DiscFamily.allCases {
            let preset = DiscPreset.defaultPreset(for: family)
            let project = DiscProject.makeNew(name: "新工程", preset: preset)
            XCTAssertNoThrow(try project.validate(), "\(family.displayNameZH) 默认工程应合法")
            XCTAssertEqual(project.discFamily, family)
            XCTAssertEqual(project.geometry.family, family)
            XCTAssertEqual(project.effectiveTone, .default)
            XCTAssertTrue(project.outputs.outputPath.hasSuffix(family == .cd ? ".wav" : ".iso"))
            if family == .bluRay {
                XCTAssertNotNil(project.bluRay, "蓝光工程必须带 bluRay 设置")
            } else {
                XCTAssertNil(project.bluRay)
            }
        }
    }
}
