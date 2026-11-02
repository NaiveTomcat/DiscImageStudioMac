import Foundation
import XCTest
@testable import DiscImageCore

final class ProjectionTests: XCTestCase {

    func testCentreMapsToZeroRadius() {
        let projection = DiscProjection(canvasSize: 2048, imageOuterRadiusMm: 57.5)
        let centre = projection.centre
        let polar = projection.polar(canvasX: centre.x, canvasY: centre.y)
        XCTAssertEqual(polar.radiusMm, 0, accuracy: 1e-9)
    }

    func testHalfCanvasMapsToImageOuterRadius() {
        let projection = DiscProjection(canvasSize: 2048, imageOuterRadiusMm: 57.5)
        XCTAssertEqual(projection.mmPerPixel, 2 * 57.5 / 2048, accuracy: 1e-12)
        // 从中心向右走 1024 像素 = 57.5 mm
        let polar = projection.polar(canvasX: projection.centre.x + 1024, canvasY: projection.centre.y)
        XCTAssertEqual(polar.radiusMm, 57.5, accuracy: 1e-9)
        XCTAssertEqual(polar.angleRadians, 0, accuracy: 1e-12)
    }

    func testPolarAndCanvasRoundTrip() {
        let projection = DiscProjection(canvasSize: 1024, imageOuterRadiusMm: 50)
        for index in 0..<32 {
            let angle = Double(index) / 32 * 2 * .pi - .pi
            for radius in [10.0, 25.0, 40.0, 49.5] {
                let point = projection.canvasPoint(radiusMm: radius, angleRadians: angle)
                let back = projection.polar(canvasX: point.x, canvasY: point.y)
                XCTAssertEqual(back.radiusMm, radius, accuracy: 1e-9)
                var delta = back.angleRadians - angle
                while delta > .pi { delta -= 2 * .pi }
                while delta < -.pi { delta += 2 * .pi }
                XCTAssertEqual(delta, 0, accuracy: 1e-9)
            }
        }
    }

    func testAngleIsCounterClockwiseFromPositiveX() {
        let projection = DiscProjection(canvasSize: 512, imageOuterRadiusMm: 25)
        // 画布 y 向下增大，所以「向上」是 −y
        let up = projection.polar(canvasX: projection.centre.x, canvasY: projection.centre.y - 100)
        XCTAssertEqual(up.angleRadians, -.pi / 2, accuracy: 1e-9)
        let right = projection.polar(canvasX: projection.centre.x + 100, canvasY: projection.centre.y)
        XCTAssertEqual(right.angleRadians, 0, accuracy: 1e-9)
    }

    func testInsideDataAreaDetection() {
        let projection = DiscProjection(canvasSize: 1024, imageOuterRadiusMm: 58)
        let centre = projection.centre
        // 中心属于夹持区，不在数据区
        XCTAssertFalse(projection.isInsideDataArea(
            canvasX: centre.x, canvasY: centre.y, innerRadiusMm: 24, outerRadiusMm: 58))
        // 半径 40 mm 处属于数据区
        let point = projection.canvasPoint(radiusMm: 40, angleRadians: 0.3)
        XCTAssertTrue(projection.isInsideDataArea(
            canvasX: point.x, canvasY: point.y, innerRadiusMm: 24, outerRadiusMm: 58))
    }
}

final class PresetTests: XCTestCase {

    func testBuiltInPresetsCoverAllFamilies() {
        XCTAssertEqual(DiscPreset.presets(for: .cd).count, 4)
        XCTAssertEqual(DiscPreset.presets(for: .dvd).count, 3)
        XCTAssertEqual(DiscPreset.presets(for: .bluRay).count, 3)
        XCTAssertEqual(DiscPreset.builtIn.count, 10)
    }

    func testPresetIDsAreUnique() {
        let ids = Set(DiscPreset.builtIn.map(\.id))
        XCTAssertEqual(ids.count, DiscPreset.builtIn.count)
    }

    func testDefaultPresetsAreValid() throws {
        for family in DiscFamily.allCases {
            let preset = DiscPreset.defaultPreset(for: family)
            XCTAssertEqual(preset.family, family)
            XCTAssertNoThrow(try preset.geometry().validate())
        }
    }

    func testMeasuredPresetsAreFlagged() {
        XCTAssertTrue(DiscPreset.presets(for: .cd).filter(\.isMeasured).count == 2)
        XCTAssertTrue(DiscPreset.presets(for: .dvd).filter(\.isMeasured).count == 1)
        XCTAssertTrue(DiscPreset.presets(for: .bluRay).filter(\.isMeasured).count == 2)
    }

    func testPresetLookupByID() {
        XCTAssertEqual(DiscPreset.preset(id: "verbatim-dvd-r-azo-43533")?.family, .dvd)
        XCTAssertNil(DiscPreset.preset(id: "nope"))
    }

    func testFamilyTokenParsing() {
        XCTAssertEqual(DiscFamily.fromProjectToken("cd"), .cd)
        XCTAssertEqual(DiscFamily.fromProjectToken("DVD"), .dvd)
        XCTAssertEqual(DiscFamily.fromProjectToken("bd"), .bluRay)
        XCTAssertEqual(DiscFamily.fromProjectToken("blu-ray"), .bluRay)
        XCTAssertNil(DiscFamily.fromProjectToken("vhs"))
        XCTAssertEqual(DiscFamily.bluRay.rawValue, "bd")
        XCTAssertEqual(DiscFamily.bluRay.displayNameZH, "蓝光")
    }

    func testOutputFormatsPerFamily() {
        XCTAssertEqual(GenerationOutputFormat.options(for: .cd), [.wav, .raw, .iso])
        XCTAssertEqual(GenerationOutputFormat.options(for: .dvd), [.iso])
        XCTAssertEqual(GenerationOutputFormat.options(for: .bluRay), [.iso])
    }
}
