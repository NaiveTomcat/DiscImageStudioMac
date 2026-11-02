import DiscImageCore
import Foundation

/// 生成进度节流器。
///
/// 引擎每秒会走过几十万个字节，直接回调 `progress` 会把 UI 淹没；这里只在进度
/// 前进幅度达到 `minimumStep`（默认 1%）或到达 100% 时回调一次。
///
/// 与 `DiscImageCore.ProgressThrottle` 的区别：那个持有 `@escaping @Sendable` 闭包，
/// 而 `DiscImageGenerator.generate` 的 `progress` 参数是**非逃逸**的，不能存进它里面。
/// 这里改成每次调用传入回调，既能节流又不要求逃逸。
final class CdProgressThrottle {
    private let minimumStep: Double
    private var lastFraction = -Double.infinity

    init(minimumStep: Double = 0.01) {
        self.minimumStep = minimumStep
    }

    func emit(
        stage: String,
        message: String,
        fraction: Double,
        to progress: (DiscProgress) -> Void
    ) {
        let clamped = min(max(fraction, 0), 1)
        guard clamped >= 1.0 || clamped - lastFraction >= minimumStep else { return }
        lastFraction = clamped
        progress(DiscProgress(stage: stage, message: message, fraction: clamped))
    }
}
