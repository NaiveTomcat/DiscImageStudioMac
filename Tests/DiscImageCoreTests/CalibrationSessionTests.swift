import XCTest
@testable import DiscImageCore

/// 会话持久化：schema 6、base64 照片、camelCase JSON、往返与校验。
final class CalibrationSessionTests: XCTestCase {
    private func makePhotoSession(
        confirmed: Bool = true,
        traces: [CalibrationCrossTrace] = []
    ) throws -> CalibrationPhotoSession {
        let image = RasterImage.gray(width: 64, height: 48, value: 200)
        let outer = (0..<8).map { index -> CalibrationPoint in
            let angle = 2 * Double.pi * Double(index) / 8
            return CalibrationPoint(xMm: 300 + 200 * cos(angle), yMm: 300 + 200 * sin(angle))
        }
        let hole = (0..<6).map { index -> CalibrationPoint in
            let angle = 2 * Double.pi * Double(index) / 6
            return CalibrationPoint(xMm: 300 + 25 * cos(angle), yMm: 300 + 25 * sin(angle))
        }
        return try CalibrationPhotoSession(
            image: image,
            outerBoundary: outer,
            holeBoundary: hole,
            discSize: .standard12cm,
            rectificationConfirmed: confirmed,
            traces: traces
        )
    }

    private func makeTrace() -> CalibrationCrossTrace {
        CalibrationCrossTrace(
            armIndex: 0,
            points: [
                CalibrationPoint(xMm: 0, yMm: 24.3),
                CalibrationPoint(xMm: 0, yMm: 30),
                CalibrationPoint(xMm: 0, yMm: 40),
                CalibrationPoint(xMm: 0, yMm: 50),
                CalibrationPoint(xMm: 0, yMm: 57.7),
            ]
        )
    }

    func testSessionRoundTripsThroughJSON() throws {
        var options = CalibrationFitOptions()
        options.searchRangeMm = 0.1
        options.fitDvdPitch = true
        let session = CalibrationSession(
            generation: CalibrationGenerationSnapshot(
                geometry: CalibrationTestSupport.dvdGeometry(
                    inner: 24,
                    outer: 58,
                    coefficients: (linear: 2e-4, quadratic: -2.6e-4, cubic: 1.8e-4)
                ),
                tone: .photo,
                generatedUtc: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            photo: try makePhotoSession(traces: [makeTrace()]),
            fitOptions: options
        )
        let data = try CalibrationSessionStore.encode(session)
        let decoded = try CalibrationSessionStore.decode(data)
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.schemaVersion, 6)
        XCTAssertEqual(decoded.generation.schemaVersion, 6)

        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"schemaVersion\" : 6"))
        XCTAssertTrue(json.contains("\"generation\""))
        XCTAssertTrue(json.contains("\"imagePngBase64\""))
        XCTAssertTrue(json.contains("\"physicalOuterRadiusMm\""))
        XCTAssertTrue(json.contains("\"pitchLinear\""))
        XCTAssertFalse(json.contains("PitchLinear"))
        // 内嵌照片可独立解码，不依赖原图路径。
        let photo = try XCTUnwrap(decoded.photo)
        let image = try photo.decodedImage()
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
    }

    func testSaveAndLoadFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calibration-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory
            .appendingPathComponent("pattern.iso.calibration.json")
        let session = CalibrationSession(
            generation: CalibrationGenerationSnapshot(geometry: CalibrationTestSupport.cdGeometry())
        )
        try CalibrationSessionStore.save(session, to: url)
        let loaded = try CalibrationSessionStore.load(from: url)
        XCTAssertEqual(loaded, session)
    }

    func testEmptyPhotoIsRejected() {
        let session = CalibrationSession(
            generation: CalibrationGenerationSnapshot(geometry: CalibrationTestSupport.dvdGeometry(inner: 24, outer: 58)),
            photo: CalibrationPhotoSession(imagePngBase64: "", physicalOuterRadiusMm: 60)
        )
        XCTAssertThrowsError(try CalibrationSessionStore.encode(session))
    }

    func testShortBoundaryIsRejected() throws {
        var photo = try makePhotoSession()
        photo.outerBoundary = Array(photo.outerBoundary.prefix(4))
        let session = CalibrationSession(
            generation: CalibrationGenerationSnapshot(geometry: CalibrationTestSupport.dvdGeometry(inner: 24, outer: 58)),
            photo: photo
        )
        XCTAssertThrowsError(try CalibrationSessionStore.encode(session))
    }

    func testTraceRequiresConfirmedRectification() throws {
        let session = CalibrationSession(
            generation: CalibrationGenerationSnapshot(geometry: CalibrationTestSupport.dvdGeometry(inner: 24, outer: 58)),
            photo: try makePhotoSession(confirmed: false, traces: [makeTrace()])
        )
        XCTAssertThrowsError(try CalibrationSessionStore.encode(session)) { error in
            XCTAssertTrue(String(describing: error).contains("尚未确认照片矫正"))
        }
    }

    func testTraceOutsideDiscIsRejected() throws {
        var trace = makeTrace()
        trace.points.append(CalibrationPoint(xMm: 61, yMm: 0))
        var photo = try makePhotoSession()
        photo.traces = [trace]
        let session = CalibrationSession(
            generation: CalibrationGenerationSnapshot(geometry: CalibrationTestSupport.dvdGeometry(inner: 24, outer: 58)),
            photo: photo
        )
        XCTAssertThrowsError(try CalibrationSessionStore.encode(session)) { error in
            XCTAssertTrue(String(describing: error).contains("超出盘面"))
        }
    }

    func testMultipleTracesAreRejected() throws {
        var photo = try makePhotoSession()
        photo.traces = [makeTrace(), makeTrace()]
        let session = CalibrationSession(
            generation: CalibrationGenerationSnapshot(geometry: CalibrationTestSupport.dvdGeometry(inner: 24, outer: 58)),
            photo: photo
        )
        XCTAssertThrowsError(try CalibrationSessionStore.encode(session)) { error in
            XCTAssertTrue(String(describing: error).contains("一条径向曲线"))
        }
    }

    func testUnsupportedSchemaVersionIsRejected() throws {
        let session = CalibrationSession(
            generation: CalibrationGenerationSnapshot(geometry: CalibrationTestSupport.dvdGeometry(inner: 24, outer: 58))
        )
        let data = try CalibrationSessionStore.encode(session)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let downgraded = json.replacingOccurrences(of: "\"schemaVersion\" : 6", with: "\"schemaVersion\" : 5")
        XCTAssertThrowsError(try CalibrationSessionStore.decode(Data(downgraded.utf8))) { error in
            XCTAssertTrue(String(describing: error).contains("版本"))
        }
    }

    func testGenerationSnapshotCarriesFixedSettings() throws {
        let generation = CalibrationGenerationSnapshot(
            geometry: CalibrationTestSupport.dvdGeometry(inner: 24, outer: 58),
            tone: .legacyBinary,
            drawingStartSector: 0,
            drawingEndSectorExclusive: 0,
            cdInterleave: false,
            generatedUtc: Date(timeIntervalSince1970: 1_700_000_123.75)
        )
        XCTAssertEqual(generation.schemaVersion, 6)
        XCTAssertEqual(generation.patternScaleMm, 58)
        XCTAssertEqual(generation.tone, .legacyBinary)
        // 生成时间截到秒，保证 JSON 往返完全相等。
        XCTAssertEqual(generation.generatedUtc.timeIntervalSince1970, 1_700_000_124, accuracy: 1e-9)
        XCTAssertEqual(
            generation.patternMillimetresPerPixel,
            CalibrationPattern.millimetresPerPixel(outerRadiusMm: 58, family: .dvd),
            accuracy: 1e-15
        )
    }
}
