import DiscImageCore
import SwiftUI

/// 预览页：`DiscProjection` 极坐标盘面渲染，文件区用黄色标出。
public struct PreviewPageView: View {
    @ObservedObject private var model: StudioModel

    public init(model: StudioModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider().overlay(UITheme.panelBorder)
                ZStack {
                    UITheme.canvasBackground
                    if let preview = model.discPreview {
                        RasterImageView(preview)
                            .aspectRatio(1, contentMode: .fit)
                            .padding(20)
                    } else {
                        EmptyStateView(
                            systemImage: "circle.dashed",
                            title: "盘面预览还没生成",
                            message: "设计页有图层后会自动合成；也可以点右上角「重新渲染」。"
                        )
                    }
                }
                legendBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(UITheme.panelBorder)
            inspector
                .frame(width: 312)
        }
        .background(UITheme.windowBackground)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("盘面预览")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(UITheme.textPrimary)
                Text("画布中心 = 盘心；环带由 DiscProjection 按 mm/像素映射。")
                    .font(.caption)
                    .foregroundStyle(UITheme.textSecondary)
            }
            Spacer()
            Picker("预览模式", selection: $model.previewMode) {
                ForEach(DiscPreviewMode.allCases) { mode in
                    Text(mode.displayNameZH).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            Button {
                model.refreshPreview()
            } label: {
                Label("重新渲染", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(UITheme.sidebarBackground)
    }

    private var legendBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                Circle().fill(UITheme.fileRegion).frame(width: 8, height: 8)
                Text(model.fileRegion == nil ? "文件区：未选择数据目录" : "文件区（黄色标记，只出现在预览上）")
                    .font(.caption2)
                    .foregroundStyle(UITheme.textTertiary)
            }
            HStack(spacing: 5) {
                Circle().fill(Color(red: 232 / 255, green: 232 / 255, blue: 232 / 255)).frame(width: 8, height: 8)
                Text("白（亮）")
            }
            HStack(spacing: 5) {
                Circle().fill(Color(red: 16 / 255, green: 16 / 255, blue: 16 / 255)).frame(width: 8, height: 8)
                Text("黑（暗）")
            }
            Spacer()
            Text("预览是采样近似，不是逐字节读回")
                .font(.caption2)
                .foregroundStyle(UITheme.textTertiary)
        }
        .font(.caption2)
        .foregroundStyle(UITheme.textSecondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(UITheme.sidebarBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(UITheme.panelBorder).frame(height: 1)
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = model.previewErrorMessage {
                    StatusBanner(.error, error)
                }
                if model.previewMode == .readback {
                    StatusBanner(.warning, "成品读回需要引擎输出的镜像；生成引擎（工作包 A/B/C）接入前，这里显示的是设计投影的灰度版本。")
                }

                SectionCard("盘片参数", systemImage: "opticaldisc") {
                    VStack(alignment: .leading, spacing: 6) {
                        MetricRow("介质", model.project.familyLabel)
                        MetricRow("内半径", String(format: "%.3f mm", model.project.geometry.innerRadiusMm), monospaced: true)
                        MetricRow("外半径", String(format: "%.3f mm", model.project.geometry.outerRadiusMm), monospaced: true)
                        MetricRow("扇区数", model.project.geometry.sectors.formatted(), monospaced: true)
                        MetricRow("螺距", String(format: "%.4f µm", model.project.geometry.spiral.pitchMm * 1000), monospaced: true)
                        MetricRow("总圈数", String(format: "%.1f", model.project.geometry.spiral.totalTurns), monospaced: true)
                        MetricRow("每圈扇区", String(format: "%.1f", model.project.geometry.spiral.sectorsPerTurn), monospaced: true)
                    }
                }

                SectionCard("影调", systemImage: "circle.lefthalf.filled") {
                    VStack(alignment: .leading, spacing: 6) {
                        MetricRow("抖动", "\(Int((model.tone.ditherStrength * 100).rounded()))%", monospaced: true)
                        MetricRow("灰度阶数", "\(model.tone.levels) 阶", monospaced: true)
                        MetricRow("亮度偏移", "\(model.tone.brightness)", monospaced: true)
                        MetricRow("sRGB 线性化", String(format: "%.0f%%", model.tone.srgbLinearization * 100), monospaced: true)
                    }
                }

                SectionCard("文件区", systemImage: "doc.on.doc") {
                    if let region = model.fileRegion {
                        VStack(alignment: .leading, spacing: 6) {
                            MetricRow("扇区区间", String(
                                format: "%.0f – %.0f",
                                region.startSector,
                                region.endSector
                            ), monospaced: true)
                            MetricRow("放置", model.project.outputs.filesAtOuterRing ? "外圈" : "内圈")
                            MetricRow("数据目录", model.project.outputs.dataDirectory.isEmpty ? "无" : "已选择")
                        }
                    } else {
                        Text("未选择数据目录：当前是纯绘图盘，整片数据区都归图案。")
                            .font(.caption)
                            .foregroundStyle(UITheme.textTertiary)
                    }
                }

                SectionCard("导出", systemImage: "square.and.arrow.down") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            exportPreview()
                        } label: {
                            Label("导出 2048 px 预览 PNG", systemImage: "photo")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Text("导出到当前工程的输出目录。")
                            .font(.caption2)
                            .foregroundStyle(UITheme.textTertiary)
                    }
                }

                if let status = model.statusMessage {
                    StatusBanner(.success, status)
                }
            }
            .padding(14)
        }
        .background(UITheme.sidebarBackground)
    }

    private func exportPreview() {
        let directory = model.project.outputs.outputPath.isEmpty
            ? ProjectStore.defaultProjectsDirectory
            : URL(fileURLWithPath: model.project.outputs.outputPath).deletingLastPathComponent()
        let url = directory.appendingPathComponent(
            "\(ProjectNaming.sanitizedFileStem(model.project.name))-preview-\(DesignComposer.previewSize).png"
        )
        do {
            try model.exportDiscPreview(to: url, size: DesignComposer.previewSize)
        } catch {
            model.alertMessage = StudioModel.message(for: error)
        }
    }
}
