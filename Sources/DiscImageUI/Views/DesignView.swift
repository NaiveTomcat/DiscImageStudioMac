import DiscImageCore
import SwiftUI
import UniformTypeIdentifiers

/// 设计页：图层画布（mm 坐标）+ 影调面板 + 合成图导出。
public struct DesignView: View {
    @ObservedObject private var model: StudioModel
    @State private var isImportingImage = false

    public init(model: StudioModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            layerPanel
                .frame(width: 232)
            Divider().overlay(UITheme.panelBorder)
            VStack(spacing: 0) {
                DesignCanvasView(model: model)
                    .padding(12)
                statusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(UITheme.panelBorder)
            inspector
                .frame(width: 304)
        }
        .background(UITheme.windowBackground)
        .fileImporter(
            isPresented: $isImportingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    do {
                        try model.addLayer(imageURL: url)
                    } catch {
                        model.alertMessage = StudioModel.message(for: error)
                    }
                }
            case .failure(let error):
                model.alertMessage = "导入图片失败：\(error.localizedDescription)"
            }
        }
        .onChange(of: model.tone) { _, _ in
            model.refreshDiscPreview()
        }
    }

    // MARK: - 左：图层列表

    private var layerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("图层")
                    .font(.headline)
                    .foregroundStyle(UITheme.textPrimary)
                Spacer()
                BadgeView("\(model.project.layers.count)")
            }
            Button {
                isImportingImage = true
            } label: {
                Label("导入图片…", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(UITheme.accent)

            Divider().overlay(UITheme.panelBorder)

            if model.project.layers.isEmpty {
                EmptyStateView(
                    systemImage: "square.stack.3d.up.slash",
                    title: "没有图层",
                    message: "导入一张图片作为盘面图案。导入后可在画布上拖动。"
                )
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(model.project.layers.enumerated()), id: \.element.id) { index, layer in
                            layerRow(layer, index: index)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(UITheme.sidebarBackground)
    }

    private func layerRow(_ layer: DesignLayer, index: Int) -> some View {
        let isSelected = model.selectedLayerID == layer.id
        let hasError = model.layerLoadErrors[layer.id] != nil
        return HStack(spacing: 8) {
            Button {
                guard let idx = model.project.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                model.project.layers[idx].visible.toggle()
                model.refreshPreview()
            } label: {
                Image(systemName: layer.visible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.visible ? UITheme.textPrimary : UITheme.textTertiary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(layer.name)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(hasError ? UITheme.danger : UITheme.textPrimary)
                Text("\(Int(layer.scale * 100))% · \(String(format: "%.1f", layer.rotationDeg))° · (\(String(format: "%.1f", layer.translateXMm)), \(String(format: "%.1f", layer.translateYMm))) mm")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(UITheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Button("上移") { model.moveLayer(id: layer.id, to: index - 1) }
                    .disabled(index == 0)
                Button("下移") { model.moveLayer(id: layer.id, to: index + 1) }
                    .disabled(index >= model.project.layers.count - 1)
                Divider()
                Button("删除", role: .destructive) { model.removeLayer(id: layer.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(UITheme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            isSelected ? UITheme.accentSoft : UITheme.panelBorder.opacity(0.22),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? UITheme.accent.opacity(0.6) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectLayer(id: layer.id) }
        .help(model.layerLoadErrors[layer.id] ?? layer.imagePath)
    }

    // MARK: - 中：状态条

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let error = model.previewErrorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(UITheme.warning)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(UITheme.textPrimary)
                    .lineLimit(2)
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(UITheme.success)
                Text("预览已合成 \(DesignComposer.previewSize) px · 画布 \(String(format: "%.1f", model.project.canvasOuterRadiusMm)) mm 半径")
                    .font(.caption)
                    .foregroundStyle(UITheme.textSecondary)
            }
            Spacer()
            Button {
                model.refreshPreview()
            } label: {
                Label("刷新预览", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(UITheme.sidebarBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(UITheme.panelBorder).frame(height: 1)
        }
    }

    // MARK: - 右：检查器

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionCard("影调", subtitle: "抖动会在中调补密度；伽马只影响黑白点密度，不改反射率。", systemImage: "circle.lefthalf.filled") {
                    TonePanel(
                        tone: model.toneBinding,
                        family: model.project.discFamily,
                        bluRayInvertMapping: Binding(
                            get: { model.project.effectiveInvertMapping },
                            set: { model.project.bluRay = BluRaySettings(invertMapping: $0) }
                        )
                    )
                }

                SectionCard("图层属性", systemImage: "slider.horizontal.3") {
                    layerInspector
                }

                SectionCard("输出", systemImage: "square.and.arrow.up") {
                    outputPanel
                }
            }
            .padding(14)
        }
        .background(UITheme.sidebarBackground)
    }

    @ViewBuilder
    private var layerInspector: some View {
        if let layer = model.selectedLayer {
            VStack(alignment: .leading, spacing: 10) {
                Text(layer.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(UITheme.textPrimary)
                if let error = model.layerLoadErrors[layer.id] {
                    StatusBanner(.error, error)
                }
                HStack {
                    Text("缩放")
                        .font(.caption)
                        .foregroundStyle(UITheme.textSecondary)
                    Spacer()
                    Text("\(Int(layer.scale * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(UITheme.textPrimary)
                }
                Slider(value: layerBinding(\.scale, fallback: 1), in: 0.05...4, step: 0.01)
                HStack {
                    Text("旋转")
                        .font(.caption)
                        .foregroundStyle(UITheme.textSecondary)
                    Spacer()
                    Text("\(String(format: "%.0f", layer.rotationDeg))°")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(UITheme.textPrimary)
                }
                Slider(value: layerBinding(\.rotationDeg, fallback: 0), in: -180...180, step: 1)
                HStack(spacing: 8) {
                    Text("位移")
                        .font(.caption)
                        .foregroundStyle(UITheme.textSecondary)
                    TextField("X mm", value: layerBinding(\.translateXMm, fallback: 0), format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    TextField("Y mm", value: layerBinding(\.translateYMm, fallback: 0), format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Spacer(minLength: 0)
                }
                Toggle("显示该图层", isOn: layerBinding(\.visible, fallback: true))
                    .toggleStyle(.switch)
                    .font(.caption)
            }
        } else {
            Text("在左侧或画布上选一个图层")
                .font(.caption)
                .foregroundStyle(UITheme.textTertiary)
        }
    }

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            MetricRow("介质", model.project.familyLabel)
            MetricRow("扇区数", model.project.geometry.sectors.formatted(), monospaced: true)
            MetricRow("螺距", String(format: "%.4f µm", model.project.geometry.spiral.pitchMm * 1000), monospaced: true)
            MetricRow("总圈数", String(format: "%.0f", model.project.geometry.spiral.totalTurns), monospaced: true)
            MetricRow("数据区", String(
                format: "%.2f – %.2f mm",
                model.project.geometry.innerRadiusMm,
                model.project.geometry.outerRadiusMm
            ), monospaced: true)

            Divider().overlay(UITheme.panelBorder)

            Button {
                startCompositeExport()
            } label: {
                Label(
                    model.compositeExportState.isRunning
                        ? "正在导出 8192 px…"
                        : "导出合成图（8192 px）",
                    systemImage: model.compositeExportState.isRunning ? "hourglass" : "square.and.arrow.down"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.project.layers.isEmpty || model.compositeExportState.isRunning)

            compositeExportStatus

            Button {
                exportDiscPreview(size: DesignComposer.previewSize)
            } label: {
                Label("导出盘面预览（2048 px）", systemImage: "circle.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Text("导出在后台执行，按钮会立即返回；完成/失败都会显示结果。预览为设计投影，不代表最终读回。")
                .font(.caption2)
                .foregroundStyle(UITheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 动作

    private func layerBinding<T>(
        _ keyPath: WritableKeyPath<DesignLayer, T>,
        fallback: T
    ) -> Binding<T> {
        Binding(
            get: { model.selectedLayer?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                guard let id = model.selectedLayerID,
                      let index = model.project.layers.firstIndex(where: { $0.id == id }) else { return }
                model.project.layers[index][keyPath: keyPath] = newValue
            }
        )
    }

    private var exportDirectory: URL {
        let path = model.project.outputs.outputPath
        if path.isEmpty {
            return ProjectStore.defaultProjectsDirectory
        }
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }

    @ViewBuilder
    private var compositeExportStatus: some View {
        switch model.compositeExportState {
        case .idle:
            EmptyView()
        case .running(let size):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在后台合成 \(size)×\(size) 图并写盘…")
                    .font(.caption2)
                    .foregroundStyle(UITheme.textSecondary)
            }
        case .succeeded(let url, let size, let duration):
            VStack(alignment: .leading, spacing: 2) {
                Text("已导出 \(size)×\(size)，用时 \(String(format: "%.1f", duration)) s")
                    .font(.caption2)
                    .foregroundStyle(UITheme.success)
                Text(url.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(UITheme.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        case .failed(let message):
            Text("导出失败：\(message)")
                .font(.caption2)
                .foregroundStyle(UITheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func startCompositeExport() {
        let size = DesignComposer.exportSize
        let url = exportDirectory.appendingPathComponent(
            "\(ProjectNaming.sanitizedFileStem(model.project.name))-composite-\(size).png"
        )
        model.startCompositeExport(to: url, size: size)
    }

    private func exportDiscPreview(size: Int) {
        let url = exportDirectory.appendingPathComponent(
            "\(ProjectNaming.sanitizedFileStem(model.project.name))-preview-\(size).png"
        )
        do {
            try model.exportDiscPreview(to: url, size: size)
        } catch {
            model.alertMessage = StudioModel.message(for: error)
        }
    }
}
