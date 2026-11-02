import Dispatch
import Foundation

/// 分块并行 + 按序回收。
///
/// 三个介质引擎的绘制循环都是「第 i 块的内容只依赖 i」，但输出必须严格按序写
/// （`SequentialSink` 不可 Seek）。所以这里把循环切成固定大小的块组：
/// 组内用 `DispatchQueue.concurrentPerform` 并行算，组内结果全部就绪后再由
/// **单线程**按原始顺序交给 `consume`（写 sink、发进度）。
///
/// 这样并行度受限于 `chunkSize`，内存占用是 `chunkSize × 单块输出`；
/// 顺序与单线程版本逐字节一致 —— 这也是各引擎优化后的回归判据。
public enum ParallelPipeline {
    /// 默认并行度：环境变量 `DISCI_MAX_WORKERS` 优先，否则取 CPU 核数但封顶 8。
    /// 封顶是因为绘制循环受内存带宽限制，超过 8 线程收益递减还会互相抢缓存。
    public static var defaultWorkers: Int {
        if let raw = ProcessInfo.processInfo.environment["DISCI_MAX_WORKERS"], let value = Int(raw), value > 0 {
            return value
        }
        return max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
    }

    /// 按块并行执行，按序消费。
    ///
    /// - Parameters:
    ///   - count: 块总数
    ///   - chunkSize: 一次并行处理的块数（决定内存上界；建议 >= workers）
    ///   - workers: **实际并发度**（把 chunk 切成这么多个连续区间并行跑）；
    ///     1 表示退化为串行（便于逐字节对拍）
    ///   - cancellation: 每块开始前检查
    ///   - produce: 计算第 i 块（必须无副作用，只依赖 i）
    ///   - consume: 按 0,1,2… 顺序接收就绪的块
    public static func run<Output>(
        count: Int,
        chunkSize: Int = 64,
        workers: Int = ParallelPipeline.defaultWorkers,
        cancellation: CancellationFlag? = nil,
        produce: @escaping (Int) throws -> Output,
        consume: (ArraySlice<Output>) throws -> Void
    ) throws {
        guard count > 0 else { return }
        let effectiveChunk = max(1, chunkSize)
        var start = 0
        while start < count {
            let end = min(start + effectiveChunk, count)
            let blockCount = end - start

            var slots = [Output?](repeating: nil, count: blockCount)
            let failure = ErrorBox()

            slots.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                let compute: (Int) -> Void = { offset in
                    if failure.hasError { return }
                    if let cancellation, cancellation.isCancelled {
                        failure.set(CancellationError())
                        return
                    }
                    do {
                        base[offset] = try produce(start + offset)
                    } catch {
                        failure.set(error)
                    }
                }
                // 把本组切成 `lanes` 个连续区间并行跑：既保证并发度恰好是
                // `workers`（不会因为 chunkSize 大而开出几十个线程），又保持
                // 每个区间内部的顺序，便于 produce 复用缓存。
                let lanes = max(1, min(workers, blockCount))
                if lanes == 1 {
                    for offset in 0..<blockCount { compute(offset) }
                } else {
                    DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                        let lower = blockCount * lane / lanes
                        let upper = blockCount * (lane + 1) / lanes
                        var offset = lower
                        while offset < upper {
                            compute(offset)
                            offset += 1
                        }
                    }
                }
            }

            if let error = failure.error { throw error }

            var ordered = [Output]()
            ordered.reserveCapacity(blockCount)
            for slot in slots {
                guard let value = slot else {
                    throw DiscError.encoding("并行任务缺少第 \(ordered.count) 块的结果")
                }
                ordered.append(value)
            }
            try consume(ordered[...])
            start = end
        }
    }
}

/// 并行任务里收集第一个错误（`concurrentPerform` 的闭包不能 throw）。
final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var hasError: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored != nil
    }

    func set(_ error: Error) {
        lock.lock()
        if stored == nil { stored = error }
        lock.unlock()
    }
}
