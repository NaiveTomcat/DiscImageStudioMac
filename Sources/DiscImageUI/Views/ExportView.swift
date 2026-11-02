import DiscImageCore
import SwiftUI
import UniformTypeIdentifiers

/// 导出页：ISO / WAV+CUE / RAW，进度与取消。
public struct ExportView: View {
    @ObservedObject private var model: StudioModel
    @ObservedObject private var job: GenerationJob
    private let scrollable: Bool
    @State private var isChoosingDataDirectory = false

    public init(model: StudioModel, scrollable: Bool = true) {
        self.model = model
        self._job = ObservedObject(wrappedValue: model.generationJob)
        self.scrollable = scrollable
    }

    public var body: some View {
        PageScaffold(scrollable: scrollable) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let reason = model.engineUnavailableReason {
                    StatusBanner(.warning, reason)
                }
                formatCard
                destinationCard
                optionsCard
                progressCard
            }
            .padding(UITheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(UITheme.windowBackground)
        .fileImporter(
            isPresented: $isChoosingDataDirectory,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.project.outputs.dataDirectory = url.path
                    model.refreshFileRegion()
                }
            case .failure(let error):
                model.alertMessage = "选择数据目录失败：\(error.localizedDescription)"
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("导出")
                .font(.title2.weight(.semibold))
                .foregroundStyle(UITheme.textPrimary)
            Text("生成与刻录解耦：先把镜像完整写到磁盘，刻录失败也不会回滚已生成的文件。")
                .font(.caption)
                .foregroundStyle(UITheme.textSecondary)
        }
    }

    // MARK: - 格式

    private var formatCard: some View {
        SectionCard("输出格式", subtitle: "格式随介质变化：CD 可写 WAV+CUE / RAW，DVD 与蓝光写 ISO。", systemImage: "doc.badge.gearshape") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("输出格式", selection: formatBinding) {
                    ForEach(model.project.availableFormats, id: \.self) { format in
                        Text(format.displayNameZH).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 18) {
                    MetricRow("介质", model.project.familyLabel)
                    MetricRow("扇区数", model.project.geometry.sectors.formatted(), monospaced: true)
                    MetricRow("预计输出", estimatedOutputSize)
                }

                formatNote
            }
        }
    }

    @ViewBuilder
    private var formatNote: some View {
        Group {
            switch model.project.outputFormat {
            case .iso:
                Text("ISO：按介质写 ISO9660（DVD／CD 数据盘）或 UDF 2.01（蓝光）。蓝光另写 `bd-r-image-v1` sidecar。")
            case .wav:
                Text("WAV + CUE：44.1 kHz / 16 bit / 双声道小端 PCM，自动旁写同名 `.cue`，可直接交给 `drutil burn -audio`。")
            case .raw:
                Text("RAW：裸扇区流，**大端**（源项目约定），用于自定义刻录链路。")
            }
        }
        .font(.caption)
        .foregroundStyle(UITheme.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var formatBinding: Binding<GenerationOutputFormat> {
        Binding(
            get: { model.project.outputFormat },
            set: { model.setOutputFormat($0) }
        )
    }

    private var estimatedOutputSize: String {
        let approx: Int64
        switch model.project.outputFormat {
        case .wav:
            approx = Int64(model.project.geometry.sectors) * 2352 + 44
        case .raw:
            approx = Int64(model.project.geometry.sectors) * 2352
        case .iso:
            approx = Int64(model.project.geometry.sectors) * 2048
        }
        return ByteCountFormatter.string(fromByteCount: approx, countStyle: .file)
    }

    // MARK: - 目的地

    private var destinationCard: some View {
        SectionCard("输出位置", subtitle: "工程文件里会记住这个路径。", systemImage: "folder") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("输出文件路径", text: Binding(
                    get: { model.project.outputs.outputPath },
                    set: { model.project.outputs.outputPath = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())

                HStack(spacing: 10) {
                    TextField("卷标（ISO/UDF）", text: Binding(
                        get: { model.project.outputs.volumeLabel },
                        set: { model.project.outputs.volumeLabel = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)

                    if model.project.outputFormat != .wav {
                        TextField("数据目录（可选）", text: Binding(
                            get: { model.project.outputs.dataDirectory },
                            set: { model.project.outputs.dataDirectory = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button("选择…") { isChoosingDataDirectory = true }
                            .buttonStyle(.bordered)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 20) {
                    Toggle("数据放外圈", isOn: Binding(
                        get: { model.project.outputs.filesAtOuterRing },
                        set: { model.project.outputs.filesAtOuterRing = $0; model.refreshFileRegion() }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    if model.project.outputFormat == .wav {
                        Toggle("旁写 .cue", isOn: Binding(
                            get: { model.project.outputs.writeCue },
                            set: { model.project.outputs.writeCue = $0 }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    }
                    if model.project.discFamily == .cd {
                        Toggle("112 帧延迟交织", isOn: Binding(
                            get: { model.project.outputs.interleave },
                            set: { model.project.outputs.interleave = $0 }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - 选项/说明

    private var optionsCard: some View {
        SectionCard("生成选项", systemImage: "gearshape.2") {
            VStack(alignment: .leading, spacing: 8) {
                MetricRow("影调抖动", "\(Int((model.tone.ditherStrength * 100).rounded()))%", monospaced: true)
                MetricRow("灰度阶数", "\(model.tone.levels) 阶", monospaced: true)
                MetricRow("设计图层", "\(model.project.layers.count) 个")
                if let region = model.fileRegion {
                    MetricRow("文件区扇区", String(format: "%.0f – %.0f", region.startSector, region.endSector), monospaced: true)
                }
                Divider().overlay(UITheme.panelBorder)
                Text("生成时会在后台先合成 \(DesignComposer.exportSize) px 设计图，再交给对应引擎。失败或取消会删除半个输出文件，不留下坏镜像。")
                    .font(.caption2)
                    .foregroundStyle(UITheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 进度

    private var progressCard: some View {
        SectionCard("进度", systemImage: "gauge.with.dots.needle.50percent") {
            VStack(alignment: .leading, spacing: 12) {
                stateView
                HStack(spacing: 10) {
                    Button {
                        start()
                    } label: {
                        Label("开始导出", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(UITheme.accent)
                    .disabled(job.state.isRunning || !model.canExport)

                    Button {
                        model.cancelGeneration()
                    } label: {
                        Label("取消", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!job.state.isRunning)

                    if case .succeeded = job.state {
                        Button("重置") { job.reset() }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                }
                if let outputURL = job.outputURL {
                    Text(outputURL.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(UITheme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch job.state {
        case .idle:
            Text(model.canExport ? "就绪" : "等待生成引擎接入（工作包 A/B/C）")
                .font(.caption)
                .foregroundStyle(UITheme.textTertiary)
        case .running(let progress):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                HStack {
                    Text(progress.message)
                        .font(.caption)
                        .foregroundStyle(UITheme.textPrimary)
                    Spacer()
                    Text(progress.stage)
                        .font(.caption2.monospaced())
                        .foregroundStyle(UITheme.textTertiary)
                }
            }
        case .succeeded(let result):
            VStack(alignment: .leading, spacing: 6) {
                StatusBanner(.success, "\(result.summary) · \(ByteCountFormatter.string(fromByteCount: result.byteCount, countStyle: .file))")
                ForEach(result.sidecarURLs, id: \.self) { url in
                    Text("旁写：\(url.lastPathComponent)")
                        .font(.caption2)
                        .foregroundStyle(UITheme.textSecondary)
                }
            }
        case .failed(let message):
            StatusBanner(.error, message)
        case .cancelled:
            StatusBanner(.warning, "已取消。未完成的输出文件已删除。")
        }
    }

    private func start() {
        let format = model.project.outputFormat
        let url = GenerationService.outputURL(for: model.project, format: format)
        model.project.outputs.outputPath = url.path
        model.startGeneration(format: format, outputURL: url)
    }
}
