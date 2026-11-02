import DiscImageCore
import SwiftUI

/// 设计画布：毫米坐标系，画布中心 = 盘心。
///
/// 图层直接按物理尺寸绘制；拖动改 `translateXMm/YMm`，缩放/旋转在右侧属性面板。
/// 磁盘内/外半径与画布边界都会画出来，方便判断图案有没有落到数据区里。
public struct DesignCanvasView: View {
    @ObservedObject private var model: StudioModel
    @State private var draggingLayerID: String?
    @State private var dragStartMm: CGSize = .zero

    public init(model: StudioModel) {
        self.model = model
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = max(min(proxy.size.width, proxy.size.height) - 28, 80)
            let centre = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let canvasOuter = model.project.canvasOuterRadiusMm
            let pointsPerMm = side / (canvasOuter * 2)

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(UITheme.canvasBackground)

                ringsView(side: side, centre: centre, pointsPerMm: pointsPerMm)

                ForEach(Array(model.project.layers.reversed())) { layer in
                    layerView(
                        layer,
                        pointsPerMm: pointsPerMm,
                        centre: centre,
                        canvasSide: side
                    )
                }

                if model.project.layers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(UITheme.accent.opacity(0.85))
                        Text("画布还是空的")
                            .font(.headline)
                            .foregroundStyle(UITheme.textPrimary)
                        Text("用左上角「导入图片」加一个图层，或直接在右侧调影调。")
                            .font(.caption)
                            .foregroundStyle(UITheme.textSecondary)
                    }
                }

                VStack {
                    HStack {
                        Text("画布边框 = \(String(format: "%.1f", canvasOuter)) mm 半径")
                        Spacer()
                        Text("内圈 \(String(format: "%.2f", model.project.geometry.innerRadiusMm)) mm · 外圈 \(String(format: "%.2f", model.project.geometry.outerRadiusMm)) mm")
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(UITheme.textTertiary)
                    .padding(10)
                    Spacer()
                    HStack {
                        LegendDot(colour: UITheme.accent, text: "设计画布")
                        LegendDot(colour: UITheme.textTertiary, text: "数据区")
                        if model.fileRegion != nil {
                            LegendDot(colour: UITheme.fileRegion, text: "文件区（预览页）")
                        }
                        Spacer()
                        Text("拖动图层可移动；缩放与旋转在右侧")
                            .font(.caption2)
                            .foregroundStyle(UITheme.textTertiary)
                    }
                    .padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(UITheme.panelBorder, lineWidth: 1)
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    // MARK: - 盘面参考线

    private func ringsView(side: CGFloat, centre: CGPoint, pointsPerMm: CGFloat) -> some View {
        Canvas { context, _ in
            let inner = model.project.geometry.innerRadiusMm * Double(pointsPerMm)
            let outer = model.project.geometry.outerRadiusMm * Double(pointsPerMm)
            let canvasRadius = side / 2

            // 数据区外缘
            context.stroke(
                Path(ellipseIn: CGRect(
                    x: centre.x - outer, y: centre.y - outer,
                    width: outer * 2, height: outer * 2
                )),
                with: .color(UITheme.textTertiary.opacity(0.6)),
                lineWidth: 1
            )
            // 数据区内缘
            context.stroke(
                Path(ellipseIn: CGRect(
                    x: centre.x - inner, y: centre.y - inner,
                    width: inner * 2, height: inner * 2
                )),
                with: .color(UITheme.textTertiary.opacity(0.45)),
                lineWidth: 1
            )
            // 画布边框（裁剪在圆里，但保留方框告诉用户导出范围）
            context.stroke(
                Path(CGRect(
                    x: centre.x - canvasRadius, y: centre.y - canvasRadius,
                    width: canvasRadius * 2, height: canvasRadius * 2
                )),
                with: .color(UITheme.accent.opacity(0.35)),
                lineWidth: 1
            )
            // 十字中心
            var crosshair = Path()
            crosshair.move(to: CGPoint(x: centre.x - 8, y: centre.y))
            crosshair.addLine(to: CGPoint(x: centre.x + 8, y: centre.y))
            crosshair.move(to: CGPoint(x: centre.x, y: centre.y - 8))
            crosshair.addLine(to: CGPoint(x: centre.x, y: centre.y + 8))
            context.stroke(crosshair, with: .color(UITheme.accent.opacity(0.7)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    // MARK: - 图层

    @ViewBuilder
    private func layerView(
        _ layer: DesignLayer,
        pointsPerMm: CGFloat,
        centre: CGPoint,
        canvasSide: CGFloat
    ) -> some View {
        let isSelected = model.selectedLayerID == layer.id
        let raster = model.layerImages[layer.id]
        let baseSize = raster.map {
            DesignComposer.baseSizeMm(
                pixelWidth: $0.width,
                pixelHeight: $0.height,
                canvasOuterRadiusMm: model.project.canvasOuterRadiusMm
            )
        } ?? CGSize(width: 40, height: 40)
        let width = max(CGFloat(baseSize.width * layer.scale) * pointsPerMm, 2)
        let height = max(CGFloat(baseSize.height * layer.scale) * pointsPerMm, 2)

        Group {
            if let raster, let cgImage = makeCGImage(from: raster), layer.visible {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: width, height: height)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(layer.visible ? UITheme.panelBackground : UITheme.panelBackground.opacity(0.4))
                    .frame(width: max(width, 60), height: max(height, 40))
                    .overlay(
                        VStack(spacing: 2) {
                            Image(systemName: layer.visible ? "photo" : "eye.slash")
                            Text(layer.name)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .foregroundStyle(UITheme.textTertiary)
                    )
            }
        }
        .rotationEffect(.degrees(layer.rotationDeg))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(UITheme.accent, lineWidth: 1.5)
            }
        }
        .position(
            x: centre.x + CGFloat(layer.translateXMm) * pointsPerMm,
            y: centre.y + CGFloat(layer.translateYMm) * pointsPerMm
        )
        .onTapGesture {
            model.selectLayer(id: layer.id)
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard let index = model.project.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                    if draggingLayerID != layer.id {
                        draggingLayerID = layer.id
                        dragStartMm = CGSize(
                            width: model.project.layers[index].translateXMm,
                            height: model.project.layers[index].translateYMm
                        )
                        model.selectLayer(id: layer.id)
                    }
                    model.project.layers[index].translateXMm =
                        dragStartMm.width + Double(value.translation.width / pointsPerMm)
                    model.project.layers[index].translateYMm =
                        dragStartMm.height + Double(value.translation.height / pointsPerMm)
                }
                .onEnded { _ in
                    draggingLayerID = nil
                    model.refreshPreview()
                }
        )
        .accessibilityLabel("图层 \(layer.name)")
    }
}

/// 图例小圆点。
struct LegendDot: View {
    let colour: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(colour)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2)
                .foregroundStyle(UITheme.textTertiary)
        }
    }
}
