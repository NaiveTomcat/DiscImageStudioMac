import DiscImageCore
import SwiftUI
import UniformTypeIdentifiers

/// 主页：模板（盘片预设）+ 最近工程。
public struct HomeView: View {
    @ObservedObject private var model: StudioModel
    private let scrollable: Bool
    @State private var isImportingProject = false

    public init(model: StudioModel, scrollable: Bool = true) {
        self.model = model
        self.scrollable = scrollable
    }

    public var body: some View {
        PageScaffold(scrollable: scrollable) {
            VStack(alignment: .leading, spacing: 20) {
                header
                newProjectSection
                recentSection
                engineNote
            }
            .padding(UITheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(UITheme.windowBackground)
        .fileImporter(
            isPresented: $isImportingProject,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try model.openProject(at: url)
                } catch {
                    model.alertMessage = StudioModel.message(for: error)
                }
            case .failure(let error):
                model.alertMessage = "打开工程失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "opticaldisc.fill")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(UITheme.accent)
                    Text("Disc Image Studio")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(UITheme.textPrimary)
                }
                Text("把小蓝鲸的图案刻进盘面物理层 —— CD / DVD / 蓝光三介质，先设计，再导出，最后刻录。")
                    .font(.callout)
                    .foregroundStyle(UITheme.textSecondary)
            }
            Spacer(minLength: 0)
            Button {
                isImportingProject = true
            } label: {
                Label("打开工程…", systemImage: "folder")
            }
            .buttonStyle(.bordered)
        }
        .padding(.bottom, 2)
    }

    // MARK: - 新建工程

    private var newProjectSection: some View {
        SectionCard("新建工程", subtitle: "从模板开始：选介质与出厂盘片预设（实盘预设带「实测」标记）", systemImage: "plus.square.on.square") {
            VStack(alignment: .leading, spacing: 16) {
                templateRow
                Divider().overlay(UITheme.panelBorder)
                Text("全部盘片预设")
                    .font(.caption)
                    .foregroundStyle(UITheme.textSecondary)
                presetGrid
            }
        }
    }

    private var templateRow: some View {
        HStack(spacing: 12) {
            ForEach(DiscFamily.allCases) { family in
                let preset = DiscPreset.defaultPreset(for: family)
                templateCard(family: family, preset: preset)
            }
        }
    }

    private func templateCard(family: DiscFamily, preset: DiscPreset) -> some View {
        Button {
            model.newProject(preset: preset)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: family == .cd ? "opticaldisc" : family == .dvd ? "opticaldisc.fill" : "circle.dashed")
                        .foregroundStyle(UITheme.accent)
                    Text(family.displayNameZH)
                        .font(.headline)
                        .foregroundStyle(UITheme.textPrimary)
                    Spacer()
                    BadgeView(family == .bluRay ? "bd" : family.rawValue)
                }
                Text(preset.displayName)
                    .font(.caption)
                    .foregroundStyle(UITheme.textSecondary)
                Text("\(preset.sectors.formatted()) 扇区 · 螺距 \(String(format: "%.4f", preset.pitchMicrometres)) µm")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(UITheme.textTertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UITheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(UITheme.accent.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// 3 列预设网格（用 HStack 手排，避免 Lazy 容器在离屏渲染里丢内容）。
    private var presetGrid: some View {
        let presets = DiscPreset.builtIn
        let rows = stride(from: 0, to: presets.count, by: 3).map { index in
            Array(presets[index..<min(index + 3, presets.count)])
        }
        return VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(row) { preset in
                        presetCard(preset)
                    }
                    if row.count < 3 {
                        ForEach(0..<(3 - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, minHeight: 1)
                        }
                    }
                }
            }
        }
    }

    private func presetCard(_ preset: DiscPreset) -> some View {
        Button {
            model.newProject(preset: preset)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(preset.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(UITheme.textPrimary)
                        .lineLimit(1)
                    if preset.isMeasured {
                        BadgeView("实测", colour: UITheme.success)
                    }
                    Spacer(minLength: 0)
                }
                Text(preset.detail)
                    .font(.caption2)
                    .foregroundStyle(UITheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(preset.family.displayNameZH) · \(preset.sectors.formatted()) 扇区")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(UITheme.textTertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(UITheme.panelBorder.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 最近工程

    private var recentSection: some View {
        SectionCard("最近工程", subtitle: "文件位置会记住；工程文件被移动或删除时这里会提示", systemImage: "clock.arrow.circlepath") {
            if model.recentProjects.isEmpty {
                EmptyStateView(
                    systemImage: "tray",
                    title: "还没有最近工程",
                    message: "从上面的模板新建一个，保存后就会出现在这里。"
                )
                .frame(height: 120)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.recentProjects) { entry in
                        recentRow(entry)
                    }
                }
            }
        }
    }

    private func recentRow(_ entry: RecentProjectEntry) -> some View {
        Button {
            model.openRecent(entry)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(UITheme.canvasBackground)
                    if let base64 = entry.thumbnailPngBase64,
                       let cgImage = decodeBase64PNGImage(base64) {
                        Image(decorative: cgImage, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "opticaldisc")
                            .font(.title2)
                            .foregroundStyle(UITheme.textTertiary)
                    }
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(UITheme.textPrimary)
                        BadgeView(entry.familyLabel)
                        if !entry.fileExists {
                            BadgeView("文件缺失", colour: UITheme.danger)
                        }
                    }
                    Text(entry.fileExists
                         ? entry.projectURL.deletingLastPathComponent().path
                         : "工程文件已移动或删除")
                        .font(.caption2)
                        .foregroundStyle(UITheme.textSecondary)
                        .lineLimit(1)
                    Text("最近打开 \(entry.lastOpenedUtc.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(UITheme.textTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(UITheme.textTertiary)
            }
            .padding(10)
            .background(UITheme.panelBorder.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 引擎状态

    private var engineNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(UITheme.textTertiary)
            Text("三介质生成引擎（CD / DVD / 蓝光）与 drutil 刻录封装都已接入；本机没有刻录机，刻录页只能验证到设备枚举与二次确认，不会真正写盘。")
                .font(.caption)
                .foregroundStyle(UITheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}
