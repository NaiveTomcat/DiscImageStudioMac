import AppKit
import DiscImageCore
import SwiftUI

/// 画布视口：只影响显示，不改变任何数据坐标。
///
/// 变换定义（都在视图坐标、y 向下）：
/// `display = centre + pan + (base − centre) × zoom`
///
/// - `base` 是「适合窗口」时的画布坐标（letterbox 之后的显示坐标）；
/// - 缩放以光标为中心时，光标下的 base 点保持不动；
/// - 会话里保存的照片像素坐标 / 盘面毫米坐标永远不经过这个变换。
public struct CanvasViewport: Equatable, Sendable {
    public static let minZoom: CGFloat = 0.25
    public static let maxZoom: CGFloat = 8

    public var zoom: CGFloat
    public var pan: CGSize

    public init(zoom: CGFloat = 1, pan: CGSize = .zero) {
        self.zoom = Self.clampZoom(zoom)
        self.pan = pan
    }

    public var isIdentity: Bool {
        abs(zoom - 1) < 1e-9 && abs(pan.width) < 1e-9 && abs(pan.height) < 1e-9
    }

    public var zoomPercent: Int { Int((zoom * 100).rounded()) }

    public static func clampZoom(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(max(value, minZoom), maxZoom)
    }

    /// base（适合窗口坐标）→ 视图显示坐标。
    public func displayPoint(base point: CGPoint, centre: CGPoint) -> CGPoint {
        CGPoint(
            x: centre.x + pan.width + (point.x - centre.x) * zoom,
            y: centre.y + pan.height + (point.y - centre.y) * zoom
        )
    }

    /// 视图显示坐标 → base（适合窗口坐标）。
    public func basePoint(display point: CGPoint, centre: CGPoint) -> CGPoint {
        guard zoom > 0 else { return point }
        return CGPoint(
            x: centre.x + (point.x - centre.x - pan.width) / zoom,
            y: centre.y + (point.y - centre.y - pan.height) / zoom
        )
    }

    /// 以视图坐标 `cursor` 为中心缩放，返回新视口（光标下的 base 点保持不动）。
    public func zoomed(by factor: CGFloat, at cursor: CGPoint, centre: CGPoint) -> CanvasViewport {
        guard factor.isFinite, factor > 0 else { return self }
        let targetZoom = Self.clampZoom(zoom * factor)
        guard targetZoom != zoom else { return self }
        let anchor = basePoint(display: cursor, centre: centre)
        var updated = self
        updated.zoom = targetZoom
        updated.pan = CGSize(
            width: cursor.x - centre.x - (anchor.x - centre.x) * targetZoom,
            height: cursor.y - centre.y - (anchor.y - centre.y) * targetZoom
        )
        return updated
    }

    /// 拖动平移（delta 为视图坐标增量）。
    public mutating func pan(by delta: CGSize) {
        pan = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
    }

    /// 双击 / 「适合窗口」：恢复 1× 且居中。
    public mutating func reset() {
        zoom = 1
        pan = .zero
    }

    /// 解析绝对缩放（工具条 +/-）。
    public func settingZoom(_ target: CGFloat, centre: CGPoint) -> CanvasViewport {
        let factor = Self.clampZoom(target) / zoom
        return zoomed(by: factor, at: centre, centre: centre)
    }
}

/// 照片视图的坐标映射：letterbox 布局 + 视口。
///
/// 这是拖控制点、点击加点唯一的坐标入口：`displayPoint` / `imagePoint` 必须成对使用。
struct PhotoCanvasMapping {
    let layout: PhotoLayout
    let viewport: CanvasViewport
    let centre: CGPoint

    func displayPoint(_ imagePoint: CalibrationPoint) -> CGPoint {
        viewport.displayPoint(base: layout.displayPoint(imagePoint), centre: centre)
    }

    func imagePoint(_ displayPoint: CGPoint) -> CalibrationPoint {
        layout.imagePoint(
            fromDisplay: viewport.basePoint(display: displayPoint, centre: centre)
        )
    }
}

/// 矫正视图的坐标映射：盘面毫米 ↔ 视图坐标（含缩放平移）。
struct TraceCanvasMapping {
    let canvasOuterRadiusMm: Double
    let side: CGFloat
    let centre: CGPoint
    let mmPerPoint: Double
    let viewport: CanvasViewport

    init(canvasOuterRadiusMm: Double, side: CGFloat, centre: CGPoint, viewport: CanvasViewport) {
        self.canvasOuterRadiusMm = canvasOuterRadiusMm
        self.side = side
        self.centre = centre
        self.mmPerPoint = canvasOuterRadiusMm * 2 / Double(max(side, 1))
        self.viewport = viewport
    }

    func baseDisplayPoint(_ discPoint: CalibrationPoint) -> CGPoint {
        CGPoint(
            x: centre.x + CGFloat(discPoint.xMm / mmPerPoint),
            y: centre.y + CGFloat(discPoint.yMm / mmPerPoint)
        )
    }

    func displayPoint(_ discPoint: CalibrationPoint) -> CGPoint {
        viewport.displayPoint(base: baseDisplayPoint(discPoint), centre: centre)
    }

    func discPoint(_ displayPoint: CGPoint) -> CalibrationPoint {
        let base = viewport.basePoint(display: displayPoint, centre: centre)
        return CalibrationPoint(
            xMm: Double(base.x - centre.x) * mmPerPoint,
            yMm: Double(base.y - centre.y) * mmPerPoint
        )
    }

    /// 缩放后的盘面像素尺寸（画 rectified 图用）。
    func scaledSide() -> CGFloat { side * viewport.zoom }
}

// MARK: - 滚轮事件桥

/// 用局部事件监听把滚轮事件接到 SwiftUI（`hitTest` 返回 nil，不抢点击/拖动）。
///
/// SwiftUI 没有公开的滚轮事件；这里只做输入桥，不替代任何 SwiftUI 视图。
struct ScrollWheelZoomCatcher: NSViewRepresentable {
    /// 参数：归一化滚动量（正 = 放大）、视图本地坐标（左上角原点，y 向下）。
    let onScroll: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> ScrollWheelZoomCatcherView {
        let view = ScrollWheelZoomCatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelZoomCatcherView, context: Context) {
        nsView.onScroll = onScroll
    }
}

final class ScrollWheelZoomCatcherView: NSView {
    var onScroll: ((CGFloat, CGPoint) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else {
            installMonitor()
        }
    }

    deinit {
        removeMonitor()
    }

    /// 不参与命中测试：滚轮由 local monitor 处理，鼠标事件留给 SwiftUI。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let local = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(local) else { return event }
            // AppKit 原点在左下，SwiftUI 在左上。
            let point = CGPoint(x: local.x, y: self.bounds.height - local.y)
            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.scrollingDeltaY * 8
            guard abs(delta) > 0.01 else { return event }
            self.onScroll?(delta, point)
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// 画布右上角的缩放工具条：「适合窗口」+ 缩放比例。
struct CanvasZoomToolbar: View {
    let viewport: CanvasViewport
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("\(viewport.zoomPercent)%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(UITheme.textSecondary)
                .frame(minWidth: 38)
            Button {
                onReset()
            } label: {
                Label("适合窗口", systemImage: "arrow.up.left.and.arrow.down.right")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .accessibleLabel("适合窗口")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.45), in: Capsule())
    }
}

private extension View {
    /// 只是给无障碍标签一个语义名的薄封装（兼容 macOS 14）。
    func accessibleLabel(_ label: String) -> some View {
        accessibilityLabel(label)
    }
}
