import CoreGraphics
import DiscImageCore
import SwiftUI

// MARK: - 卡片

/// 带标题的分组卡片：六个页面共用。
public struct SectionCard<Content: View>: View {
    public let title: String
    public let subtitle: String?
    public let systemImage: String?
    @ViewBuilder public let content: () -> Content

    public init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(UITheme.accent)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(UITheme.textPrimary)
                Spacer(minLength: 0)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(UITheme.textSecondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UITheme.panelBackground, in: RoundedRectangle(cornerRadius: UITheme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: UITheme.cornerRadius)
                .stroke(UITheme.panelBorder, lineWidth: 1)
        )
    }
}

// MARK: - 页面滚动容器

/// 页面外壳：应用里是可滚动页面；离屏快照（`ImageRenderer`）不渲染
/// `ScrollView` 的 AppKit 承载视图，所以测试传 `scrollable: false`。
public struct PageScaffold<Content: View>: View {
    public let scrollable: Bool
    @ViewBuilder public let content: () -> Content

    public init(scrollable: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.scrollable = scrollable
        self.content = content
    }

    public var body: some View {
        Group {
            if scrollable {
                ScrollView { content() }
            } else {
                content()
            }
        }
    }
}

// MARK: - 状态条

public struct StatusBanner: View {
    public enum Kind {
        case info, success, warning, error

        var colour: Color {
            switch self {
            case .info: return UITheme.accent
            case .success: return UITheme.success
            case .warning: return UITheme.warning
            case .error: return UITheme.danger
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }
    }

    public let kind: Kind
    public let text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.colour)
            Text(text)
                .font(.callout)
                .foregroundStyle(UITheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(kind.colour.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(kind.colour.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - 空状态

public struct EmptyStateView: View {
    public let systemImage: String
    public let title: String
    public let message: String

    public init(systemImage: String, title: String, message: String) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(UITheme.accent.opacity(0.8))
            Text(title)
                .font(.headline)
                .foregroundStyle(UITheme.textPrimary)
            Text(message)
                .font(.caption)
                .foregroundStyle(UITheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - 只读指标

public struct MetricRow: View {
    public let label: String
    public let value: String
    public var monospaced: Bool

    public init(_ label: String, _ value: String, monospaced: Bool = false) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(UITheme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .caption.monospacedDigit() : .caption)
                .foregroundStyle(UITheme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 位图显示

/// 把 `RasterImage` 直接显示出来（不经过 AppKit 视图）。
public struct RasterImageView: View {
    public let raster: RasterImage?
    public let label: String?

    public init(_ raster: RasterImage?, label: String? = nil) {
        self.raster = raster
        self.label = label
    }

    public var body: some View {
        ZStack {
            if let raster, let cgImage = makeCGImage(from: raster) {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                if let label {
                    VStack {
                        Spacer()
                        Text(label)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(8)
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(UITheme.canvasBackground)
                    .overlay(
                        Text("暂无预览")
                            .font(.caption)
                            .foregroundStyle(UITheme.textTertiary)
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 影调面板

/// 影调面板：抖动 / 亮度 / sRGB 线性化 / CD 灰阶阶数 / BD 极性。
///
/// 这个面板只改 `ToneProfile`，不直接操作引擎；合成与预览由 `StudioModel` 负责。
public struct TonePanel: View {
    @Binding public var tone: ToneProfile
    public let family: DiscFamily
    @Binding public var bluRayInvertMapping: Bool

    public init(
        tone: Binding<ToneProfile>,
        family: DiscFamily,
        bluRayInvertMapping: Binding<Bool>
    ) {
        self._tone = tone
        self.family = family
        self._bluRayInvertMapping = bluRayInvertMapping
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("抖动强度")
                        .font(.caption)
                        .foregroundStyle(UITheme.textSecondary)
                    Spacer()
                    Text("\(Int((tone.ditherStrength * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(UITheme.textPrimary)
                }
                Slider(value: $tone.ditherStrength, in: 0...1, step: 0.01)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("亮度")
                        .font(.caption)
                        .foregroundStyle(UITheme.textSecondary)
                    Spacer()
                    Text("\(tone.brightness)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(UITheme.textPrimary)
                }
                Slider(
                    value: Binding(
                        get: { Double(tone.brightness) },
                        set: { tone.brightness = Int($0.rounded()) }
                    ),
                    in: Double(ToneProfile.minBrightness)...Double(ToneProfile.maxBrightness),
                    step: 1
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("sRGB 线性化")
                        .font(.caption)
                        .foregroundStyle(UITheme.textSecondary)
                    Spacer()
                    Text(String(format: "%.0f%%", tone.srgbLinearization * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(UITheme.textPrimary)
                }
                Slider(value: $tone.srgbLinearization, in: 0...1, step: 0.01)
            }

            if family == .cd {
                VStack(alignment: .leading, spacing: 6) {
                    Text("灰阶层数")
                        .font(.caption)
                        .foregroundStyle(UITheme.textSecondary)
                    Picker("灰阶层数", selection: $tone.levels) {
                        Text("2 阶（黑白）").tag(ToneProfile.twoLevels)
                        Text("4 阶（CD 专用）").tag(ToneProfile.fourLevels)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            } else {
                Text("\(family.displayNameZH) 固定 2 阶黑白")
                    .font(.caption2)
                    .foregroundStyle(UITheme.textTertiary)
            }

            if family == .bluRay {
                Toggle(isOn: $bluRayInvertMapping) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("极性反转")
                            .font(.caption)
                            .foregroundStyle(UITheme.textPrimary)
                        Text("3T/6T 映射反相后重刻")
                            .font(.caption2)
                            .foregroundStyle(UITheme.textTertiary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }
}

// MARK: - 小徽章

public struct BadgeView: View {
    public let text: String
    public let colour: Color

    public init(_ text: String, colour: Color = UITheme.accent) {
        self.text = text
        self.colour = colour
    }

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(colour.opacity(0.18), in: Capsule())
            .foregroundStyle(colour)
    }
}
