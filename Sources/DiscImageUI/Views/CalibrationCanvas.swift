import DiscImageCore
import SwiftUI

// MARK: - 照片控制点画布

/// 第一步：在实拍照片上拖动两组控制点（实体外缘 / 中心孔）。
///
/// 视图变换（缩放/平移）只作用于显示；拖点的结果仍是照片像素坐标。
/// 坐标入口统一走 `PhotoCanvasMapping`（letterbox + zoom + pan）。
struct CalibrationPhotoCanvas: View {
    let image: RasterImage
    let outerBoundary: [CalibrationPoint]
    let holeBoundary: [CalibrationPoint]
    let onMove: (CalibrationModel.BoundaryKind, Int, CalibrationPoint) -> Void

    @State private var viewport = CanvasViewport()
    @State private var panStart: CGSize?
    @State private var magnifyStart: CanvasViewport?

    private static let space = "calibration.photo"

    var body: some View {
        GeometryReader { proxy in
            let layout = PhotoLayout(
                imageSize: CGSize(width: image.width, height: image.height),
                bounds: proxy.size
            )
            let centre = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let mapping = PhotoCanvasMapping(layout: layout, viewport: viewport, centre: centre)
            let imageCentre = CGPoint(x: centre.x + viewport.pan.width, y: centre.y + viewport.pan.height)

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(UITheme.canvasBackground)

                ScrollWheelZoomCatcher { delta, point in
                    viewport = viewport.zoomed(
                        by: pow(1.002, delta),
                        at: point,
                        centre: centre
                    )
                }
                .allowsHitTesting(false)

                if let cgImage = makeCGImage(from: image) {
                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(
                            width: layout.imageRect.width * viewport.zoom,
                            height: layout.imageRect.height * viewport.zoom
                        )
                        .position(imageCentre)
                }

                // 空白处拖动平移（控制点在上层，拖动仍优先移动点）。
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(panGesture())

                ForEach(Array(outerBoundary.enumerated()), id: \.offset) { index, point in
                    controlPoint(
                        at: mapping.displayPoint(point),
                        colour: UITheme.accent,
                        label: "外\(index + 1)",
                        zoom: viewport.zoom
                    )
                    .gesture(dragGesture(kind: .outer, index: index, mapping: mapping))
                }

                ForEach(Array(holeBoundary.enumerated()), id: \.offset) { index, point in
                    controlPoint(
                        at: mapping.displayPoint(point),
                        colour: Color(red: 0.98, green: 0.45, blue: 0.72),
                        label: "孔\(index + 1)",
                        zoom: viewport.zoom
                    )
                    .gesture(dragGesture(kind: .hole, index: index, mapping: mapping))
                }

                VStack {
                    HStack {
                        Spacer()
                        CanvasZoomToolbar(viewport: viewport) { viewport.reset() }
                    }
                    Spacer()
                }
                .padding(10)
            }
            .coordinateSpace(name: Self.space)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(UITheme.panelBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { viewport.reset() }
            )
            .simultaneousGesture(magnifyGesture(centre: centre))
        }
    }

    private func controlPoint(at point: CGPoint, colour: Color, label: String, zoom: CGFloat) -> some View {
        let size = 13 * min(max(zoom, 0.6), 2.2)
        return Circle()
            .fill(colour.opacity(0.22))
            .overlay(Circle().stroke(colour, lineWidth: 1.5))
            .frame(width: size, height: size)
            .overlay(
                Text(label)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(colour)
                    .offset(y: -size * 0.85)
            )
            .position(point)
            .contentShape(Circle())
            .accessibilityLabel("控制点 \(label)")
    }

    private func dragGesture(
        kind: CalibrationModel.BoundaryKind,
        index: Int,
        mapping: PhotoCanvasMapping
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                onMove(kind, index, mapping.imagePoint(value.location))
            }
    }

    private func panGesture() -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if panStart == nil { panStart = viewport.pan }
                guard let panStart else { return }
                viewport.pan = CGSize(
                    width: panStart.width + value.translation.width,
                    height: panStart.height + value.translation.height
                )
            }
            .onEnded { _ in panStart = nil }
    }

    private func magnifyGesture(centre: CGPoint) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyStart == nil { magnifyStart = viewport }
                guard let magnifyStart else { return }
                viewport = magnifyStart.zoomed(
                    by: max(value.magnification, 0.01),
                    at: value.startLocation,
                    centre: centre
                )
            }
            .onEnded { _ in magnifyStart = nil }
    }
}

/// 照片在给定区域内的等比布局（「适合窗口」的 base 坐标）。
struct PhotoLayout {
    let imageRect: CGRect
    let scale: CGFloat

    init(imageSize: CGSize, bounds: CGSize) {
        let inset: CGFloat = 14
        let availableWidth = max(bounds.width - inset * 2, 1)
        let availableHeight = max(bounds.height - inset * 2, 1)
        guard imageSize.width > 0, imageSize.height > 0 else {
            imageRect = CGRect(x: bounds.width / 2, y: bounds.height / 2, width: 1, height: 1)
            scale = 1
            return
        }
        scale = min(availableWidth / imageSize.width, availableHeight / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        imageRect = CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    func displayPoint(_ point: CalibrationPoint) -> CGPoint {
        CGPoint(
            x: imageRect.minX + CGFloat(point.xMm) * scale,
            y: imageRect.minY + CGFloat(point.yMm) * scale
        )
    }

    func imagePoint(fromDisplay point: CGPoint) -> CalibrationPoint {
        CalibrationPoint(
            xMm: Double((point.x - imageRect.minX) / scale),
            yMm: Double((point.y - imageRect.minY) / scale)
        )
    }
}

// MARK: - 矫正后描线画布

/// 第二步：在矫正后的正视盘面上描一条从内到外的径向曲线。
///
/// - 点击空白：加点；拖动圆点：移动已有点并选中；
/// - 拖动空白：平移；滚轮/捏合：以光标为中心缩放；双击：复位；
/// - 橙色折线：候选参数的预测曲线；红色点：与预测偏差较大的点。
struct CalibrationTraceCanvas: View {
    let image: RasterImage?
    let canvasOuterRadiusMm: Double
    let physicalOuterRadiusMm: Double
    let holeRadiusMm: Double
    let tracePoints: [CalibrationPoint]
    let prediction: [CalibrationPoint]
    let outlierIndices: [Int]
    let selectedIndex: Int?
    let onAdd: (CalibrationPoint) -> Void
    let onMove: (Int, CalibrationPoint) -> Void
    let onDelete: () -> Void

    @State private var viewport = CanvasViewport()
    @State private var panStart: CGSize?
    @State private var magnifyStart: CanvasViewport?
    @State private var lastTap: (time: Date, location: CGPoint)?

    private static let space = "calibration.trace"

    var body: some View {
        GeometryReader { proxy in
            let side = max(min(proxy.size.width, proxy.size.height) - 24, 80)
            let centre = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let mapping = TraceCanvasMapping(
                canvasOuterRadiusMm: canvasOuterRadiusMm,
                side: side,
                centre: centre,
                viewport: viewport
            )

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(UITheme.canvasBackground)

                ScrollWheelZoomCatcher { delta, point in
                    viewport = viewport.zoomed(by: pow(1.002, delta), at: point, centre: centre)
                }
                .allowsHitTesting(false)

                if let image, let cgImage = makeCGImage(from: image) {
                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: mapping.scaledSide(), height: mapping.scaledSide())
                        .position(
                            x: centre.x + viewport.pan.width,
                            y: centre.y + viewport.pan.height
                        )
                }

                rings(mapping: mapping)

                // 空白区域：点击加点 / 拖动平移。
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .gesture(panGesture())
                    .simultaneousGesture(
                        SpatialTapGesture(coordinateSpace: .named(Self.space))
                            .onEnded { value in
                                // 双击复位（第一次点击加的点在第二次点击时被选中，这里删掉它）。
                                let now = Date()
                                if let lastTap,
                                   now.timeIntervalSince(lastTap.time) < 0.35,
                                   hypot(value.location.x - lastTap.location.x,
                                         value.location.y - lastTap.location.y) < 8 {
                                    self.lastTap = nil
                                    onDelete()
                                    viewport.reset()
                                    return
                                }
                                self.lastTap = (now, value.location)
                                onAdd(mapping.discPoint(value.location))
                            }
                    )

                if prediction.count >= 2 {
                    predictionPath(mapping: mapping)
                        .stroke(
                            Color(red: 1.0, green: 0.62, blue: 0.2),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )
                }

                ForEach(Array(tracePoints.enumerated()), id: \.offset) { index, point in
                    let isOutlier = outlierIndices.contains(index)
                    let isSelected = selectedIndex == index
                    Circle()
                        .fill(isOutlier ? UITheme.danger : UITheme.accent)
                        .overlay(
                            Circle().stroke(
                                isSelected ? Color.white : Color.black.opacity(0.55),
                                lineWidth: isSelected ? 2 : 1
                            )
                        )
                        .frame(width: isSelected ? 11 : 8, height: isSelected ? 11 : 8)
                        .position(mapping.displayPoint(point))
                        .contentShape(Circle().inset(by: -4))
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                                .onChanged { value in
                                    onMove(index, mapping.discPoint(value.location))
                                }
                        )
                }

                VStack {
                    HStack {
                        Spacer()
                        CanvasZoomToolbar(viewport: viewport) { viewport.reset() }
                    }
                    Spacer()
                }
                .padding(10)
            }
            .coordinateSpace(name: Self.space)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(UITheme.panelBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .focusable()
            .onDeleteCommand(perform: onDelete)
            .simultaneousGesture(magnifyGesture(centre: centre))
        }
    }

    private func rings(mapping: TraceCanvasMapping) -> some View {
        Canvas { context, _ in
            let displayCentre = CGPoint(
                x: mapping.centre.x + mapping.viewport.pan.width,
                y: mapping.centre.y + mapping.viewport.pan.height
            )
            func circle(_ radiusMm: Double) -> Path {
                let radius = CGFloat(radiusMm / mapping.mmPerPoint) * mapping.viewport.zoom
                return Path(ellipseIn: CGRect(
                    x: displayCentre.x - radius,
                    y: displayCentre.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
            }
            context.stroke(
                circle(physicalOuterRadiusMm),
                with: .color(UITheme.accent.opacity(0.5)),
                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )
            context.stroke(
                circle(holeRadiusMm),
                with: .color(Color.white.opacity(0.3)),
                lineWidth: 1
            )
            var crosshair = Path()
            crosshair.move(to: CGPoint(x: displayCentre.x - 6, y: displayCentre.y))
            crosshair.addLine(to: CGPoint(x: displayCentre.x + 6, y: displayCentre.y))
            crosshair.move(to: CGPoint(x: displayCentre.x, y: displayCentre.y - 6))
            crosshair.addLine(to: CGPoint(x: displayCentre.x, y: displayCentre.y + 6))
            context.stroke(crosshair, with: .color(UITheme.textTertiary), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private func predictionPath(mapping: TraceCanvasMapping) -> Path {
        var path = Path()
        for (index, point) in prediction.enumerated() {
            let display = mapping.displayPoint(point)
            if index == 0 {
                path.move(to: display)
            } else {
                path.addLine(to: display)
            }
        }
        return path
    }

    private func panGesture() -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if panStart == nil { panStart = viewport.pan }
                guard let panStart else { return }
                viewport.pan = CGSize(
                    width: panStart.width + value.translation.width,
                    height: panStart.height + value.translation.height
                )
            }
            .onEnded { _ in panStart = nil }
    }

    private func magnifyGesture(centre: CGPoint) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyStart == nil { magnifyStart = viewport }
                guard let magnifyStart else { return }
                viewport = magnifyStart.zoomed(
                    by: max(value.magnification, 0.01),
                    at: value.startLocation,
                    centre: centre
                )
            }
            .onEnded { _ in magnifyStart = nil }
    }
}

// MARK: - 图例

struct CalibrationLegendDot: View {
    let colour: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(text)
                .font(.caption2)
                .foregroundStyle(UITheme.textTertiary)
        }
    }
}
