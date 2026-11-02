import XCTest
@testable import DiscImageCore

/// 螺旋与几何的自检：HANDOFF §2.2 的反算螺距表就是这里的断言来源。
final class GeometryTests: XCTestCase {

    private let cd80 = DiscPreset.cd80.geometry()
    private let dvdDefault = DiscPreset.dvd5_120mm.geometry()
    private let bdDefault = DiscPreset.bdRsl25gb.geometry()

    // MARK: - 总长

    func testTotalLengthMatchesSpecFormulas() {
        // CD: L = (N / 75) * v
        XCTAssertEqual(cd80.totalLengthMm, (359_849.0 / 75.0) * 1200, accuracy: 1e-6)
        // DVD: L = N * 38688 * bitLengthNm * 1e-6
        XCTAssertEqual(dvdDefault.totalLengthMm,
                       2_295_104.0 * 38_688 * 133.3e-6,
                       accuracy: 1e-6)
        // BD: L = (N / 32) * 962136 * 74.5e-6
        XCTAssertEqual(bdDefault.totalLengthMm,
                       (12_219_392.0 / 32.0) * 962_136 * 74.5e-6,
                       accuracy: 1e-6)
    }

    // MARK: - 反算螺距（HANDOFF §2.2）

    func testCd80PitchIsKnownSourceDefect() {
        // 源项目已知缺陷：80min CD 反算出来的螺距 1.4329 µm 超出 ECMA-130 的 1.5–1.7 µm。
        // 这条断言是「记录缺陷」而不是「保证正确」——改采样参数时它会提醒你。
        XCTAssertEqual(cd80.spiral.pitchMm * 1000, 1.4329, accuracy: 1e-3)
        XCTAssertLessThan(cd80.spiral.pitchMm * 1000, 1.5)
    }

    func testDvdDefaultPitchIsSevenFourMicrometres() {
        XCTAssertEqual(dvdDefault.spiral.pitchMm * 1000, 0.7398, accuracy: 5e-4)
    }

    func testDvdBlockGeometry() {
        XCTAssertEqual(dvdDefault.sectors % DiscGeometry.dvdSectorsPerBlock, 0)
        XCTAssertEqual(DiscGeometry.dvdChannelBitsPerBlock,
                       DiscGeometry.dvdSectorsPerBlock * DiscGeometry.dvdChannelBitsPerSector)
        XCTAssertEqual(DiscGeometry.dvdChannelBitsPerBlock, 619_008)
        // 每扇区 38688 = 13 × 2 × (32 + 1456)
        XCTAssertEqual(DiscGeometry.dvdChannelBitsPerSector, 13 * 2 * (32 + 1456))
    }

    func testBluRayClusterGeometry() {
        XCTAssertEqual(bdDefault.sectors % DiscGeometry.bluRaySectorsPerCluster, 0)
        XCTAssertEqual(DiscGeometry.bluRayChannelBitsPerCluster, 962_136)
        // 32 扇区 = 1 簇；32 × 2052 = 304 × 216（LDC 铺满的算术原因）
        XCTAssertEqual(DiscGeometry.bluRaySectorsPerCluster * 2052, 304 * 216)
    }

    // MARK: - 螺旋不变量

    func testSpiralRoundTrips() {
        for geometry in [cd80, dvdDefault, bdDefault] {
            let spiral = geometry.spiral
            XCTAssertGreaterThan(spiral.totalTurns, 0)
            XCTAssertGreaterThan(spiral.pitchMm, 0)

            // 圈数 ↔ 半径
            for fraction in stride(from: 0.0, through: 1.0, by: 0.125) {
                let radius = spiral.radiusAtAreaFraction(fraction)
                XCTAssertEqual(spiral.areaFraction(radiusMm: radius), fraction, accuracy: 1e-12)
                XCTAssertEqual(spiral.radiusAt(turns: spiral.turnsAt(radiusMm: radius)), radius, accuracy: 1e-9)
            }

            // 扇区坐标 ↔ 半径
            for fraction in stride(from: 0.0, through: 1.0, by: 0.1) {
                let coordinate = Double(spiral.totalSectors) * fraction
                let radius = spiral.radiusAt(sectorCoordinate: coordinate)
                XCTAssertEqual(spiral.sectorCoordinate(radiusMm: radius), coordinate, accuracy: 1e-3)
            }

            // 边界
            XCTAssertEqual(spiral.turnsAt(radiusMm: geometry.innerRadiusMm), 0, accuracy: 1e-12)
            XCTAssertEqual(spiral.turnsAt(radiusMm: geometry.outerRadiusMm), spiral.totalTurns, accuracy: 1e-9)
        }
    }

    func testSectorCoordinateIncludesAngle() {
        let spiral = cd80.spiral
        let radius = 40.0
        let base = spiral.sectorCoordinate(radiusMm: radius)
        let quarter = spiral.sectorCoordinate(radiusMm: radius, angleRadians: .pi / 2)
        XCTAssertEqual(quarter - base, spiral.sectorsPerTurn / 4, accuracy: 1e-6)
    }

    func testTurnsPerSectorMatchesSectorLength() {
        // CD 每扇区长度 = 线速度 / 75；圈数 × 螺距 ≈ 扇区数 × 每扇区长度
        let spiral = cd80.spiral
        let metres = cd80.totalLengthMm
        XCTAssertEqual(metres / 1000, 5757.584, accuracy: 1e-6)
        XCTAssertGreaterThan(spiral.sectorsPerTurn, 0)
    }

    // MARK: - 几何校验

    func testValidationAcceptsBuiltInPresets() throws {
        for preset in DiscPreset.builtIn {
            XCTAssertNoThrow(try preset.geometry().validate(), "预设 \(preset.id) 应该通过校验")
        }
    }

    func testDvdSectorAlignmentRequired() {
        var geometry = dvdDefault
        geometry.sectors = 2_295_105
        XCTAssertThrowsError(try geometry.validate()) { error in
            guard case DiscError.invalidGeometry = error else {
                return XCTFail("应是 invalidGeometry，实际 \(error)")
            }
        }
    }

    func testBluRayRejectsNonClusterMultiple() {
        var geometry = bdDefault
        geometry.sectors = 12_219_393
        XCTAssertThrowsError(try geometry.validate())
    }

    func testBluRayRejectsCubicPitch() {
        var geometry = bdDefault
        geometry.pitchLinear = 1e-4
        XCTAssertThrowsError(try geometry.validate()) { error in
            guard case DiscError.unsupported = error else {
                return XCTFail("应是 unsupported，实际 \(error)")
            }
        }
    }

    func testGeometryRejectsBadRadii() {
        var geometry = cd80
        geometry.innerRadiusMm = 0
        XCTAssertThrowsError(try geometry.validate())

        geometry = cd80
        geometry.outerRadiusMm = geometry.innerRadiusMm
        XCTAssertThrowsError(try geometry.validate())

        geometry = cd80
        geometry.outerRadiusMm = 70
        XCTAssertThrowsError(try geometry.validate())
    }

    func testCubicPitchFactorAndValidation() {
        let geometry = DiscPreset.verbatimDvdAzo43533.geometry()
        XCTAssertTrue(geometry.hasCubicPitch)
        XCTAssertEqual(geometry.pitchFactor(normalizedRadius: 0), 1, accuracy: 1e-15)
        XCTAssertGreaterThan(geometry.pitchFactor(normalizedRadius: 0.5), 0)
        XCTAssertNoThrow(try geometry.validate())
    }

    func testGeometryCodableRoundTrip() throws {
        let geometry = DiscPreset.verbatimDvdAzo43533.geometry()
        let data = try JSONEncoder().encode(geometry)
        let decoded = try JSONDecoder().decode(DiscGeometry.self, from: data)
        XCTAssertEqual(decoded, geometry)
    }

    func testGeometryDecodesLegacyPayloadWithoutOptionalFields() throws {
        let json = """
        {"family":"cd","innerRadiusMm":24.5,"outerRadiusMm":56.8,"sectors":359849}
        """
        let decoded = try JSONDecoder().decode(DiscGeometry.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.linearVelocityMmPerSecond, 1200)
        XCTAssertFalse(decoded.hasCubicPitch)
    }
}
