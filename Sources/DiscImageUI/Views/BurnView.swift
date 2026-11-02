import DiscImageCore
import SwiftUI

/// 刻录页：设备枚举 → 空白检查 → 倍速 → 二次确认 → 进度/取消。
///
/// 所有刻录动作都走 `BurnServicing`：真机是 `DrutilBurnAdapter`（包装工作包 E 的
/// `DrutilBurner`），测试用 `MockBurnAdapter`（包装 `MockBurnService`）。
/// 本机没有刻录机/光盘，所以只能验证到「枚举 → 空白检查 → 二次确认」。
public struct BurnView: View {
    @ObservedObject private var model: StudioModel
    @ObservedObject private var workflow: BurnWorkflow
    private let scrollable: Bool
    @State private var localError: String?

    public init(model: StudioModel, scrollable: Bool = true) {
        self.model = model
        self._workflow = ObservedObject(wrappedValue: model.burnWorkflow)
        self.scrollable = scrollable
    }

    public var body: some View {
        PageScaffold(scrollable: scrollable) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let localError {
                    StatusBanner(.error, localError)
                }
                if case .failed(let message) = workflow.phase {
                    StatusBanner(.error, message)
                }
                deviceCard
                imageCard
                confirmationCard
            }
            .padding(UITheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(UITheme.windowBackground)
        .onAppear {
            if workflow.devices.isEmpty, !workflow.phase.isBusy {
                workflow.refreshDevices()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("刻录")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(UITheme.textPrimary)
                Text("刻录只使用已导出的镜像；失败不会回滚生成的文件。")
                    .font(.caption)
                    .foregroundStyle(UITheme.textSecondary)
            }
            Spacer()
            BadgeView("服务：\(workflow.serviceName)", colour: UITheme.textSecondary)
            Button {
                localError = nil
                workflow.refreshDevices()
            } label: {
                Label("刷新设备", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(workflow.phase.isBusy)
        }
    }

    // MARK: - 设备

    private var deviceCard: some View {
        SectionCard("设备与介质", subtitle: "`drutil list` 枚举设备，`drutil status` 判断空白与容量。", systemImage: "externaldrive") {
            if workflow.devices.isEmpty {
                EmptyStateView(
                    systemImage: "externaldrive.badge.questionmark",
                    title: "没有检测到刻录机",
                    message: workflow.phase.isBusy
                        ? "正在枚举设备…"
                        : "本机可能没有刻录机。连接外置刻录机后点「刷新设备」；也可以先在导出页生成镜像。"
                )
                .frame(height: 150)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Text("设备")
                            .font(.caption)
                            .foregroundStyle(UITheme.textSecondary)
                            .frame(width: 42, alignment: .leading)
                        Picker("设备", selection: Binding(
                            get: { workflow.selectedDeviceID ?? workflow.devices.first?.id ?? "" },
                            set: { id in
                                do {
                                    try workflow.selectDevice(id)
                                    localError = nil
                                } catch {
                                    localError = StudioModel.message(for: error)
                                }
                            }
                        )) {
                            ForEach(workflow.devices) { device in
                                Text(device.resolvedDisplayName).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320)
                        Spacer()
                        mediaBadge
                    }

                    HStack(spacing: 12) {
                        Text("倍速")
                            .font(.caption)
                            .foregroundStyle(UITheme.textSecondary)
                            .frame(width: 42, alignment: .leading)
                        Picker("倍速", selection: Binding(
                            get: { workflow.selectedSpeed },
                            set: { workflow.selectSpeed($0) }
                        )) {
                            ForEach(workflow.speeds) { speed in
                                Text(speed.label).tag(speed)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        Spacer()
                    }

                    if let device = workflow.selectedDevice {
                        Text("标识：\(device.id) · \(device.vendor.isEmpty ? "未知厂商" : device.vendor)")
                            .font(.caption2)
                            .foregroundStyle(UITheme.textTertiary)
                    }
                }
            }
        }
    }

    private var mediaBadge: some View {
        switch workflow.mediaStatus {
        case .blank:
            return BadgeView(workflow.mediaStatus.displayNameZH, colour: UITheme.success)
        case .notBlank:
            return BadgeView(workflow.mediaStatus.displayNameZH, colour: UITheme.danger)
        case .noMedia:
            return BadgeView(workflow.mediaStatus.displayNameZH, colour: UITheme.warning)
        case .unknown:
            return BadgeView(workflow.mediaStatus.displayNameZH, colour: UITheme.textSecondary)
        }
    }

    // MARK: - 镜像

    private var imageCard: some View {
        SectionCard("待刻录镜像", subtitle: "镜像路径来自导出页的工程输出。", systemImage: "doc") {
            let format = model.project.outputFormat
            let imageURL = GenerationService.outputURL(for: model.project, format: format)
            HStack(spacing: 12) {
                Image(systemName: "opticaldisc")
                    .font(.title2)
                    .foregroundStyle(UITheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(imageURL.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(UITheme.textPrimary)
                    Text(imageURL.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(UITheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                BadgeView(format.displayNameZH)
                BadgeView(workflow.burnMediaKindLabel(for: format), colour: UITheme.textSecondary)
            }

            if !FileManager.default.fileExists(atPath: imageURL.path) {
                Text("镜像还不存在：请先在导出页生成。")
                    .font(.caption)
                    .foregroundStyle(UITheme.warning)
            }

            Button {
                prepare(imageURL: imageURL, format: format)
            } label: {
                Label("检查并准备刻录", systemImage: "checkmark.shield")
            }
            .buttonStyle(.borderedProminent)
            .tint(UITheme.accent)
            .disabled(workflow.phase.isBusy || workflow.devices.isEmpty)
            .padding(.top, 4)
        }
    }

    // MARK: - 二次确认 / 进度

    @ViewBuilder
    private var confirmationCard: some View {
        switch workflow.phase {
        case .needsConfirmation(let request):
            SectionCard("二次确认", subtitle: "这一步之前不会对盘片做任何写入。", systemImage: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 12) {
                    StatusBanner(.warning, workflow.confirmationMessage)
                    MetricRow("设备", workflow.selectedDevice?.resolvedDisplayName ?? request.deviceID)
                    MetricRow("镜像", request.imageURL.lastPathComponent)
                    MetricRow("介质类型", request.mediaKind.rawValue)
                    MetricRow("倍速", request.speed.label)
                    MetricRow("容量状态", workflow.mediaStatus.displayNameZH)
                    HStack(spacing: 10) {
                        Button(role: .destructive) {
                            Task { await workflow.confirmAndBurn() }
                        } label: {
                            Label("确认刻录", systemImage: "flame")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(UITheme.danger)
                        Button("取消") {
                            workflow.resetPhase()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        case .burning:
            SectionCard("刻录中", systemImage: "flame") {
                VStack(alignment: .leading, spacing: 10) {
                    if let fraction = workflow.progress.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Text(workflow.progress.message)
                        .font(.caption)
                        .foregroundStyle(UITheme.textPrimary)
                    Button {
                        workflow.cancel()
                    } label: {
                        Label("取消刻录", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }
        case .finished(let message):
            SectionCard("完成", systemImage: "checkmark.seal") {
                VStack(alignment: .leading, spacing: 10) {
                    StatusBanner(.success, message)
                    Button("继续") { workflow.resetPhase() }
                        .buttonStyle(.bordered)
                }
            }
        case .cancelled:
            SectionCard("已取消", systemImage: "stop.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    StatusBanner(.warning, "刻录已取消。已经写入的部分可能让这张盘报废。")
                    Button("继续") { workflow.resetPhase() }
                        .buttonStyle(.bordered)
                }
            }
        case .idle, .scanning, .ready, .failed:
            disclaimer
        }
    }

    private var disclaimer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(UITheme.textTertiary)
            Text("本机没有刻录机与光盘时，这里只能验证到「设备枚举 → 空白检查 → 二次确认」；接上光驱后，确认刻录会通过 `drutil` / `hdiutil` 真正写入。")
                .font(.caption)
                .foregroundStyle(UITheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func prepare(imageURL: URL, format: GenerationOutputFormat) {
        localError = nil
        do {
            try workflow.prepareBurn(
                imageURL: imageURL,
                format: format,
                volumeLabel: model.project.outputs.volumeLabel
            )
        } catch {
            localError = StudioModel.message(for: error)
        }
    }
}

private extension BurnWorkflow {
    func burnMediaKindLabel(for format: GenerationOutputFormat) -> String {
        BurnWorkflow.mediaKind(for: format).rawValue
    }
}
