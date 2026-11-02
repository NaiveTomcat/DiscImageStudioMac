import DiscImageCore
import SwiftUI

// MARK: - 照片控制点画布

/// 第一步：在实拍照片上拖动两组控制点（实体外缘 / 中心孔）。
///
/// 坐标换算：`CalibrationPoint` 是照片像素、y 向下；界面按「等比缩放 + 居中」显示。
struct CalibrationPhotoCanvas: View {
    let image: RasterImage
    let outerBoundary: [CalibrationPoint]
    let holeBoundary: [CalibrationPoint]
    let onMove: (CalibrationModel.BoundaryKind, Int, CalibrationPoint) -> Void

    private static let space = "calibration.photo"

    var body: some View {
        GeometryReader { proxy in
            let layout = PhotoLayout(
                imageSize: CGSize(width: image.width, height: image.height),
                bounds: proxy.size
            )
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(UITheme.canvasBackground)

                if let cgImage = makeCGImage(from: image) {
                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: layout.imageRect.width, height: layout.imageRect.height)
                        .position(x: layout.imageRect.midX, y: layout.imageRect.midY)
                        .overlay {
                            Rectangle()
                                .stroke(UITheme.panelBorder, lineWidth: 1)
                                .frame(width: layout.imageRect.width, height: layout.imageRect.height)
                                .position(x: layout.imageRect.midX, y: layout.imageRect.midY)
                        }
                }

                ForEach(Array(outerBoundary.enumerated()), id: \.offset) { index, point in
                    controlPoint(
                        at: layout.displayPoint(point),
                        colour: UITheme.accent,
                        label: "外\(index + 1)"
                    )
                    .gesture(dragGesture(kind: .outer, index: index, layout: layout))
                }

                ForEach(Array(holeBoundary.enumerated()), id: \.offset) { index, point in
                    controlPoint(
                        at: layout.displayPoint(point),
                        colour: Color(red: 0.98, green: 0.45, blue: 0.72),
                        label: "孔\(index + 1)"
                    )
                    .gesture(dragGesture(kind: .hole, index: index, layout: layout))
                }
            }
            .coordinateSpace(name: Self.space)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(UITheme.panelBorder, lineWidth: 1)
            )
        }
    }

    private func controlPoint(at point: CGPoint, colour: Color, label: String) -> some View {
        Circle()
            .fill(colour.opacity(0.22))
            .overlay(Circle().stroke(colour, lineWidth: 1.5))
            .frame(width: 13, height: 13)
            .overlay(
                Text(label)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(colour)
                    .offset(y: -11)
            )
            .position(point)
            .contentShape(Circle())
            .accessibilityLabel("控制点 \(label)")
    }

    private func dragGesture(
        kind: CalibrationModel.BoundaryKind,
        index: Int,
        layout: PhotoLayout
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                onMove(kind, index, layout.imagePoint(fromDisplay: value.location))
            }
    }
}

/// 照片在给定区域内的等比布局。
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
/// - 点击空白：加点；
/// - 拖动圆点：移动已有点并选中；
/// - Delete（或面板上的按钮）：删除选中点；
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

    private static let space = "calibration.trace"

    var body: some View {
        GeometryReader { proxy in
            let side = max(min(proxy.size.width, proxy.size.height) - 24, 80)
            let centre = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let mmPerPoint = canvasOuterRadiusMm * 2 / Double(side)

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(UITheme.canvasBackground)

                if let image, let cgImage = makeCGImage(from: image) {
                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: side, height: side)
                        .position(centre)
                }

                rings(centre: centre, side: side, mmPerPoint: mmPerPoint)

                // 空白区域点击加点（放在图上、点下面，避免抢点的拖动）。
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: side, height: side)
                    .position(centre)
                    .gesture(
                        SpatialTapGesture(coordinateSpace: .named(Self.space))
                            .onEnded { value in
                                onAdd(discPoint(
                                    display: value.location,
                                    centre: centre,
                                    mmPerPoint: mmPerPoint
                                ))
                            }
                    )

                if prediction.count >= 2 {
                    predictionPath(centre: centre, mmPerPoint: mmPerPoint)
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
                        .position(displayPoint(point, centre: centre, mmPerPoint: mmPerPoint))
                        .contentShape(Circle().inset(by: -4))
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                                .onChanged { value in
                                    onMove(
                                        index,
                                        discPoint(
                                            display: value.location,
                                            centre: centre,
                                            mmPerPoint: mmPerPoint
                                        )
                                    )
                                }
                        )
                }
            }
            .coordinateSpace(name: Self.space)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(UITheme.panelBorder, lineWidth: 1)
            )
            .focusable()
            .onDeleteCommand(perform: onDelete)
        }
    }

    private func rings(centre: CGPoint, side: CGFloat, mmPerPoint: Double) -> some View {
        Canvas { context, _ in
            func circle(_ radiusMm: Double) -> Path {
                let radius = CGFloat(radiusMm / mmPerPoint)
                return Path(ellipseIn: CGRect(
                    x: centre.x - radius,
                    y: centre.y - radius,
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
            crosshair.move(to: CGPoint(x: centre.x - 6, y: centre.y))
            crosshair.addLine(to: CGPoint(x: centre.x + 6, y: centre.y))
            crosshair.move(to: CGPoint(x: centre.x, y: centre.y - 6))
            crosshair.addLine(to: CGPoint(x: centre.x, y: centre.y + 6))
            context.stroke(crosshair, with: .color(UITheme.textTertiary), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private func predictionPath(centre: CGPoint, mmPerPoint: Double) -> Path {
        var path = Path()
        for (index, point) in prediction.enumerated() {
            let display = displayPoint(point, centre: centre, mmPerPoint: mmPerPoint)
            if index == 0 {
                path.move(to: display)
            } else {
                path.addLine(to: display)
            }
        }
        return path
    }

    private func displayPoint(
        _ point: CalibrationPoint,
        centre: CGPoint,
        mmPerPoint: Double
    ) -> CGPoint {
        CGPoint(
            x: centre.x + CGFloat(point.xMm / mmPerPoint),
            y: centre.y + CGFloat(point.yMm / mmPerPoint)
        )
    }

    private func discPoint(
        display point: CGPoint,
        centre: CGPoint,
        mmPerPoint: Double
    ) -> CalibrationPoint {
        CalibrationPoint(
            xMm: Double((point.x - centre.x)) * mmPerPoint,
            yMm: Double((point.y - centre.y)) * mmPerPoint
        )
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
