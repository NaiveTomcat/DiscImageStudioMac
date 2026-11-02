import DiscImageCore
import XCTest
@testable import DiscImageUI

/// 画布缩放/平移：坐标换算 round-trip 与光标锚定。
final class CanvasViewportTests: XCTestCase {
    private let centre = CGPoint(x: 400, y: 300)

    func testBaseDisplayRoundTripWithZoomAndPan() {
        let viewport = CanvasViewport(zoom: 2.4, pan: CGSize(width: 37, height: -21))
        let base = CGPoint(x: 123.25, y: 456.75)

        let display = viewport.displayPoint(base: base, centre: centre)
        let back = viewport.basePoint(display: display, centre: centre)

        XCTAssertEqual(back.x, base.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, base.y, accuracy: 1e-9)
        // 显示点应确实被缩放/平移。
        XCTAssertNotEqual(display.x, base.x)
        XCTAssertNotEqual(display.y, base.y)
    }

    func testZoomAtCursorKeepsAnchorPoint() {
        let viewport = CanvasViewport()
        let cursor = CGPoint(x: 620, y: 180)
        let anchor = viewport.basePoint(display: cursor, centre: centre)

        let zoomed = viewport.zoomed(by: 3, at: cursor, centre: centre)

        XCTAssertEqual(zoomed.zoom, 3, accuracy: 1e-9)
        let anchorAfter = zoomed.basePoint(display: cursor, centre: centre)
        XCTAssertEqual(anchorAfter.x, anchor.x, accuracy: 1e-9)
        XCTAssertEqual(anchorAfter.y, anchor.y, accuracy: 1e-9)
        // 光标下显示位置保持不变，等价于 base 点映射回同一个光标。
        let display = zoomed.displayPoint(base: anchor, centre: centre)
        XCTAssertEqual(display.x, cursor.x, accuracy: 1e-9)
        XCTAssertEqual(display.y, cursor.y, accuracy: 1e-9)
    }

    func testZoomClampingAndSettingZoom() {
        let zoomed = CanvasViewport().zoomed(by: 1000, at: centre, centre: centre)
        XCTAssertEqual(zoomed.zoom, CanvasViewport.maxZoom, accuracy: 1e-9)

        let shrunk = CanvasViewport().zoomed(by: 0.0001, at: centre, centre: centre)
        XCTAssertEqual(shrunk.zoom, CanvasViewport.minZoom, accuracy: 1e-9)

        let explicit = CanvasViewport().settingZoom(2.5, centre: centre)
        XCTAssertEqual(explicit.zoom, 2.5, accuracy: 1e-9)
    }

    func testPanAndReset() {
        var viewport = CanvasViewport()
        viewport.pan(by: CGSize(width: 30, height: -12))
        viewport.pan(by: CGSize(width: -5, height: 2))
        XCTAssertEqual(viewport.pan.width, 25, accuracy: 1e-9)
        XCTAssertEqual(viewport.pan.height, -10, accuracy: 1e-9)
        XCTAssertFalse(viewport.isIdentity)

        viewport.reset()
        XCTAssertTrue(viewport.isIdentity)
        XCTAssertEqual(viewport.zoomPercent, 100)
    }

    /// 照片坐标 round-trip：letterbox + 缩放 + 平移同时生效，误差远小于 1 px。
    func testPhotoMappingRoundTripWithLetterboxAndViewport() {
        let layout = PhotoLayout(
            imageSize: CGSize(width: 400, height: 300),
            bounds: CGSize(width: 800, height: 600)
        )
        let viewport = CanvasViewport(zoom: 2.4, pan: CGSize(width: 37, height: -21))
        let mapping = PhotoCanvasMapping(layout: layout, viewport: viewport, centre: centre)

        for imagePoint in [
            CalibrationPoint(xMm: 0, yMm: 0),
            CalibrationPoint(xMm: 123.4, yMm: 87.6),
            CalibrationPoint(xMm: 399, yMm: 299),
            CalibrationPoint(xMm: 200.5, yMm: 150.25),
        ] {
            let display = mapping.displayPoint(imagePoint)
            let back = mapping.imagePoint(display)
            XCTAssertEqual(back.xMm, imagePoint.xMm, accuracy: 1e-9)
            XCTAssertEqual(back.yMm, imagePoint.yMm, accuracy: 1e-9)
        }
    }

    /// 盘面毫米 ↔ 视图坐标 round-trip（描线画布）。
    func testTraceMappingRoundTrip() {
        let viewport = CanvasViewport(zoom: 4.5, pan: CGSize(width: -60, height: 25))
        let mapping = TraceCanvasMapping(
            canvasOuterRadiusMm: 63,
            side: 640,
            centre: centre,
            viewport: viewport
        )

        for discPoint in [
            CalibrationPoint(xMm: 0, yMm: 0),
            CalibrationPoint(xMm: 24.5, yMm: -12),
            CalibrationPoint(xMm: -30.25, yMm: 41.5),
        ] {
            let back = mapping.discPoint(mapping.displayPoint(discPoint))
            XCTAssertEqual(back.xMm, discPoint.xMm, accuracy: 1e-9)
            XCTAssertEqual(back.yMm, discPoint.yMm, accuracy: 1e-9)
        }
    }
}
