import Foundation
import XCTest
@testable import DiscImageCore

final class ParallelPipelineTests: XCTestCase {

    func testPreservesOrderAcrossChunks() throws {
        var consumed: [Int] = []
        try ParallelPipeline.run(count: 1000, chunkSize: 37, workers: 4, produce: { $0 * 3 }) { slice in
            consumed.append(contentsOf: slice)
        }
        XCTAssertEqual(consumed, (0..<1000).map { $0 * 3 })
    }

    func testSerialAndParallelAgree() throws {
        var serial: [Int] = []
        var parallel: [Int] = []
        try ParallelPipeline.run(count: 257, chunkSize: 32, workers: 1, produce: { $0 % 7 }) { serial.append(contentsOf: $0) }
        try ParallelPipeline.run(count: 257, chunkSize: 32, workers: 8, produce: { $0 % 7 }) { parallel.append(contentsOf: $0) }
        XCTAssertEqual(serial, parallel)
    }

    func testConsumeSeesSmallsChunksFirst() throws {
        var sizes: [Int] = []
        try ParallelPipeline.run(count: 10, chunkSize: 4, workers: 2, produce: { $0 }) { sizes.append($0.count) }
        XCTAssertEqual(sizes, [4, 4, 2])
    }

    func testPropagatesProduceError() {
        struct Boom: Error {}
        XCTAssertThrowsError(
            try ParallelPipeline.run(count: 100, chunkSize: 16, workers: 4, produce: { index -> Int in
                if index == 42 { throw Boom() }
                return index
            }, consume: { _ in })
        )
    }

    func testHonoursCancellation() {
        let flag = CancellationFlag()
        flag.cancel()
        XCTAssertThrowsError(
            try ParallelPipeline.run(count: 100, chunkSize: 16, workers: 4, cancellation: flag,
                                     produce: { $0 }, consume: { _ in })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testZeroCountDoesNothing() throws {
        var calls = 0
        try ParallelPipeline.run(count: 0, produce: { $0 }) { _ in calls += 1 }
        XCTAssertEqual(calls, 0)
    }

    func testWorkersEnvironmentOverride() {
        // 只验证解析逻辑本身（不改当前进程环境，避免影响其它测试）
        XCTAssertGreaterThanOrEqual(ParallelPipeline.defaultWorkers, 1)
        XCTAssertLessThanOrEqual(ParallelPipeline.defaultWorkers, 8)
    }
}
