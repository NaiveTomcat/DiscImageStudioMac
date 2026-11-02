import DiscImageCore
import SwiftUI
import UniformTypeIdentifiers

/// 应用主窗口：六工作区外壳（主页 / 设计 / 预览 / 导出 / 刻录 / 标定）。
///
/// `DiscImageStudioApp` 只调用 `MainWindowView()`，所以这个签名必须保持。
public struct MainWindowView: View {
    @StateObject private var model: StudioModel
    @State private var isImportingProject = false
    @State private var isExportingProject = false
    @State private var saveDocument: DataFileDocument?
    @State private var saveFilename: String = "工程.discproj"

    public init(model: StudioModel? = nil) {
        _model = StateObject(wrappedValue: model ?? StudioModel())
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 216)
            Divider().overlay(UITheme.panelBorder)
            VStack(spacing: 0) {
                topBar
                Divider().overlay(UITheme.panelBorder)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(UITheme.windowBackground)
        .frame(minWidth: 1100, minHeight: 720)
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
        .fileExporter(
            isPresented: $isExportingProject,
            document: saveDocument,
            contentType: ProjectFileTypes.project,
            defaultFilename: saveFilename
        ) { result in
            switch result {
            case .success(let url):
                do {
                    try model.saveProject(to: url)
                } catch {
                    model.alertMessage = StudioModel.message(for: error)
                }
            case .failure(let error):
                model.alertMessage = "保存工程失败：\(error.localizedDescription)"
            }
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("好") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DiscImageStudio.openProject"))) { _ in
            isImportingProject = true
        }
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "opticaldisc.fill")
                    .font(.title3)
                    .foregroundStyle(UITheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Disc Image Studio")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(UITheme.textPrimary)
                    Text("v\(DiscImageCore.version) · 三介质")
                        .font(.caption2)
                        .foregroundStyle(UITheme.textTertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            VStack(spacing: 3) {
                ForEach(StudioModel.Page.allCases) { page in
                    navButton(page)
                }
            }
            .padding(.horizontal, 10)

            Divider().overlay(UITheme.panelBorder).padding(.vertical, 10)

            projectSummary
                .padding(.horizontal, 16)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    isImportingProject = true
                } label: {
                    Label("打开工程…", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)

                Button {
                    saveProject()
                } label: {
                    Label("保存工程", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)

                Button {
                    prepareSaveAs()
                } label: {
                    Label("另存为…", systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
            }
            .font(.callout)
            .foregroundStyle(UITheme.textSecondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(UITheme.sidebarBackground)
    }

    private func navButton(_ page: StudioModel.Page) -> some View {
        let selected = model.page == page
        return Button {
            model.navigate(to: page)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbolName)
                    .frame(width: 18)
                    .foregroundStyle(selected ? UITheme.accent : UITheme.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(page.title)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? UITheme.textPrimary : UITheme.textSecondary)
                    Text(page.subtitle)
                        .font(.caption2)
                        .foregroundStyle(UITheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                selected ? UITheme.accentSoft : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var projectSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("当前工程")
                .font(.caption2)
                .foregroundStyle(UITheme.textTertiary)
            Text(model.project.name)
                .font(.callout.weight(.medium))
                .foregroundStyle(UITheme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 5) {
                BadgeView(model.project.familyLabel)
                if model.isDirty {
                    BadgeView("未保存", colour: UITheme.warning)
                }
            }
            if let url = model.projectURL {
                Text(url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(UITheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("尚未保存到文件")
                    .font(.caption2)
                    .foregroundStyle(UITheme.textTertiary)
            }
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.page.title)
                    .font(.headline)
                    .foregroundStyle(UITheme.textPrimary)
                Text(model.page.subtitle)
                    .font(.caption2)
                    .foregroundStyle(UITheme.textTertiary)
            }
            Spacer()
            if let status = model.statusMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(UITheme.success)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(UITheme.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(UITheme.panelBorder.opacity(0.3), in: Capsule())
            }
            Text(model.displayTitle)
                .font(.caption)
                .foregroundStyle(UITheme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(UITheme.sidebarBackground)
    }

    // MARK: - 页面

    @ViewBuilder
    private var content: some View {
        switch model.page {
        case .home:
            HomeView(model: model)
        case .design:
            DesignView(model: model)
        case .preview:
            PreviewPageView(model: model)
        case .export:
            ExportView(model: model)
        case .burn:
            BurnView(model: model)
        case .calibration:
            CalibrationView(model: model)
        }
    }

    // MARK: - 保存

    private func saveProject() {
        do {
            if let url = model.projectURL {
                try model.saveProject(to: url)
            } else {
                let directory = ProjectStore.defaultProjectsDirectory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory
                    .appendingPathComponent(ProjectNaming.sanitizedFileStem(model.project.name))
                    .appendingPathExtension(DiscProject.fileExtension)
                try model.saveProject(to: url)
            }
        } catch {
            model.alertMessage = StudioModel.message(for: error)
        }
    }

    private func prepareSaveAs() {
        do {
            saveDocument = DataFileDocument(data: try ProjectStore().encode(model.project))
            saveFilename = "\(ProjectNaming.sanitizedFileStem(model.project.name)).\(DiscProject.fileExtension)"
            isExportingProject = true
        } catch {
            model.alertMessage = StudioModel.message(for: error)
        }
    }
}
