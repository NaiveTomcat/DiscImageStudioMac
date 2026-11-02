import DiscImageCore
import SwiftUI
import UniformTypeIdentifiers

/// 标定页：标定会话路径 + 三次轨距系数（DVD）或极性（蓝光），写入工程文件。
///
/// 这是可交互的占位：只把参数落到 `.discproj` 并做几何校验；
/// 真正的标定拍照流程与系数拟合属于后续工作。
public struct CalibrationView: View {
    @ObservedObject private var model: StudioModel
    private let scrollable: Bool
    @State private var isChoosingSession = false
    @State private var validationMessage: String?

    public init(model: StudioModel, scrollable: Bool = true) {
        self.model = model
        self.scrollable = scrollable
    }

    public var body: some View {
        PageScaffold(scrollable: scrollable) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let validationMessage {
                    StatusBanner(.warning, validationMessage)
                }
                sessionCard
                pitchCard
                if model.project.discFamily == .bluRay { polarityCard }
                applyCard
            }
            .padding(UITheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(UITheme.windowBackground)
        .fileImporter(
            isPresented: $isChoosingSession,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.project.calibrationSessionPath = url.path
                }
            case .failure(let error):
                model.alertMessage = "选择标定会话失败：\(error.localizedDescription)"
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("标定")
                .font(.title2.weight(.semibold))
                .foregroundStyle(UITheme.textPrimary)
            Text("把实测盘片的标定结果写进工程：标定会话路径 + 轨距系数（DVD 三次轨距 / 蓝光极性）。")
                .font(.caption)
                .foregroundStyle(UITheme.textSecondary)
        }
    }

    private var sessionCard: some View {
        SectionCard("标定会话", subtitle: "标定会话目录（照片、扫描记录）只记路径，不复制进工程。", systemImage: "camera") {
            HStack(spacing: 10) {
                TextField("会话目录路径（可选）", text: Binding(
                    get: { model.project.calibrationSessionPath ?? "" },
                    set: { model.project.calibrationSessionPath = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                Button("选择…") { isChoosingSession = true }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var pitchCard: some View {
        SectionCard(
            "轨距分布",
            subtitle: "系数定义：pitch × (1 + c₁x + c₂x² + c₃x³)，x = (r − rᵢ)/(rₒ − rᵢ)。蓝光使用恒定轨距，系数必须为 0。",
            systemImage: "chart.xyaxis.line"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                coefficientField("一次系数 c₁", value: Binding(
                    get: { model.project.geometry.pitchLinear },
                    set: { model.project.geometry.pitchLinear = $0 }
                ), placeholder: "-3.9256854e-05")
                coefficientField("二次系数 c₂", value: Binding(
                    get: { model.project.geometry.pitchQuadratic },
                    set: { model.project.geometry.pitchQuadratic = $0 }
                ), placeholder: "6.9647959e-05")
                coefficientField("三次系数 c₃", value: Binding(
                    get: { model.project.geometry.pitchCubic },
                    set: { model.project.geometry.pitchCubic = $0 }
                ), placeholder: "-4.6709190e-05")

                Divider().overlay(UITheme.panelBorder)
                factorSummary
            }
            .disabled(model.project.discFamily == .bluRay)
            .opacity(model.project.discFamily == .bluRay ? 0.55 : 1)
        }
    }

    private func coefficientField(
        _ label: String,
        value: Binding<Double>,
        placeholder: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(UITheme.textSecondary)
                .frame(width: 96, alignment: .leading)
            TextField(placeholder, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .frame(maxWidth: 260)
            Spacer()
        }
    }

    private var factorSummary: some View {
        let geometry = model.project.geometry
        let factors = stride(from: 0.0, through: 1.0, by: 0.25).map { x in
            (x, geometry.pitchFactor(normalizedRadius: x))
        }
        let minimum = factors.map(\.1).min() ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            MetricRow("平均螺距", String(format: "%.4f µm", geometry.spiral.pitchMm * 1000), monospaced: true)
            MetricRow("总圈数", String(format: "%.1f", geometry.spiral.totalTurns), monospaced: true)
            MetricRow("轨距因子范围", String(
                format: "%.5f … %.5f",
                factors.map(\.1).min() ?? 1,
                factors.map(\.1).max() ?? 1
            ), monospaced: true)
            HStack(spacing: 6) {
                Image(systemName: minimum > 0 ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(minimum > 0 ? UITheme.success : UITheme.danger)
                Text(minimum > 0
                     ? "多项式在 0…1 上恒正，可以保存"
                     : "多项式在 0…1 上出现非正值，几何校验会拒绝保存")
                    .font(.caption2)
                    .foregroundStyle(UITheme.textSecondary)
            }
        }
    }

    private var polarityCard: some View {
        SectionCard("蓝光极性", systemImage: "circle.righthalf.filled") {
            Toggle(isOn: Binding(
                get: { model.project.effectiveInvertMapping },
                set: { model.project.bluRay = BluRaySettings(invertMapping: $0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("3T/6T 映射反转")
                        .font(.callout)
                        .foregroundStyle(UITheme.textPrimary)
                    Text("源项目默认不反转；实盘出现极性相反时再打开。")
                        .font(.caption2)
                        .foregroundStyle(UITheme.textTertiary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var applyCard: some View {
        SectionCard("写入工程", systemImage: "square.and.arrow.down.on.square") {
            VStack(alignment: .leading, spacing: 10) {
                Text("应用后会按当前几何重新校验（DVD 扇区必须 %16、蓝光 %32 且外半径 ≤ 60 mm）。")
                    .font(.caption)
                    .foregroundStyle(UITheme.textTertiary)
                Button {
                    apply()
                } label: {
                    Label("应用标定参数", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(UITheme.accent)
                if let status = model.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(UITheme.success)
                }
            }
        }
    }

    private func apply() {
        validationMessage = nil
        do {
            try model.applyCalibration(
                sessionPath: model.project.calibrationSessionPath,
                pitchLinear: model.project.geometry.pitchLinear,
                pitchQuadratic: model.project.geometry.pitchQuadratic,
                pitchCubic: model.project.geometry.pitchCubic,
                invertMapping: model.project.effectiveInvertMapping
            )
        } catch {
            validationMessage = StudioModel.message(for: error)
        }
    }
}
