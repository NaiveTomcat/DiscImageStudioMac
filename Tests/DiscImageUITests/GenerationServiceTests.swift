import DiscImageCore
import DiscImageUI
import XCTest

/// 生成调度：引擎分派、落盘、失败清理、取消、导出页作业状态机。
final class GenerationServiceTests: XCTestCase {
    private final class ProgressCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [DiscProgress] = []

        func append(_ progress: DiscProgress) {
            lock.lock()
            storage.append(progress)
            lock.unlock()
        }

        var values: [DiscProgress] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// 写 128 字节后取消自己的引擎。
    private struct SelfCancellingGenerator: DiscImageGenerator {
        var family: DiscFamily { .dvd }

        func generate(
            _ request: GenerationRequest,
            to sink: SequentialSink,
            progress: @Sendable (DiscProgress) -> Void
        ) throws -> GenerationResult {
            try sink.write([UInt8](repeating: 0x11, count: 128))
            request.cancellation.cancel()
            try request.cancellation.check()
            return GenerationResult(byteCount: 128, summary: "不应到达")
        }
    }

    private struct FailingAfterWriteGenerator: DiscImageGenerator {
        var family: DiscFamily { .dvd }

        func generate(
            _ request: GenerationRequest,
            to sink: SequentialSink,
            progress: @Sendable (DiscProgress) -> Void
        ) throws -> GenerationResult {
            try sink.write([UInt8](repeating: 0x22, count: 256))
            throw DiscError.encoding("模拟编码失败")
        }
    }

    private func makeProject() -> DiscProject {
        UITestSupport.sampleProject(family: .dvd)
    }

    // MARK: - 落盘成功

    func testGenerateWritesOutputAndReportsProgress() throws {
        let directory = try UITestSupport.makeTempDirectory("generate-ok")
        defer { UITestSupport.removeQuietly(directory) }

        let collector = ProgressCollector()
        let service = GenerationService(factory: { family in
            StubGenerator(family: family, byteCount: 4096)
        })
        let output = directory.appendingPathComponent("disc.iso")
        let result = try service.generate(
            project: makeProject(),
            tone: .default,
            image: RasterImage.gray(width: 64, height: 64, value: 128),
            format: .iso,
            outputURL: output,
            dataDirectory: nil,
            progress: { collector.append($0) },
            cancellation: CancellationFlag()
        )

        XCTAssertEqual(result.byteCount, 4096)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, 4096)
        XCTAssertFalse(collector.values.isEmpty, "应至少上报一次进度")
        XCTAssertEqual(collector.values.last?.fraction, 1)
    }

    // MARK: - 失败清理

    func testFailureDeletesPartialOutput() throws {
        let directory = try UITestSupport.makeTempDirectory("generate-fail")
        defer { UITestSupport.removeQuietly(directory) }
        let output = directory.appendingPathComponent("disc.iso")

        let service = GenerationService(factory: { family in
            FailingAfterWriteGenerator()
        })
        XCTAssertThrowsError(try service.generate(
            project: makeProject(),
            tone: .default,
            image: RasterImage.gray(width: 32, height: 32, value: 0),
            format: .iso,
            outputURL: output,
            dataDirectory: nil,
            progress: { _ in },
            cancellation: CancellationFlag()
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "失败不应留下半个镜像")
    }

    func testUnsupportedEngineLeavesNoFile() throws {
        let directory = try UITestSupport.makeTempDirectory("generate-unsupported")
        defer { UITestSupport.removeQuietly(directory) }
        let output = directory.appendingPathComponent("disc.iso")

        let service = GenerationService(factory: { _ in
            throw DiscError.unsupported("模拟：引擎尚未接入")
        })
        XCTAssertThrowsError(try service.generate(
            project: makeProject(),
            tone: .default,
            image: RasterImage.gray(width: 32, height: 32, value: 0),
            format: .iso,
            outputURL: output,
            dataDirectory: nil,
            progress: { _ in },
            cancellation: CancellationFlag()
        )) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("尚未接入"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - 取消

    func testCancellationBeforeStartThrows() throws {
        let directory = try UITestSupport.makeTempDirectory("generate-cancel-before")
        defer { UITestSupport.removeQuietly(directory) }
        let output = directory.appendingPathComponent("disc.iso")
        let cancellation = CancellationFlag()
        cancellation.cancel()

        let service = GenerationService(factory: { family in StubGenerator(family: family) })
        XCTAssertThrowsError(try service.generate(
            project: makeProject(),
            tone: .default,
            image: RasterImage.gray(width: 32, height: 32, value: 0),
            format: .iso,
            outputURL: output,
            dataDirectory: nil,
            progress: { _ in },
            cancellation: cancellation
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCancellationDuringGenerationDeletesPartialFile() throws {
        let directory = try UITestSupport.makeTempDirectory("generate-cancel-mid")
        defer { UITestSupport.removeQuietly(directory) }
        let output = directory.appendingPathComponent("disc.iso")

        let service = GenerationService(factory: { _ in SelfCancellingGenerator() })
        XCTAssertThrowsError(try service.generate(
            project: makeProject(),
            tone: .default,
            image: RasterImage.gray(width: 32, height: 32, value: 0),
            format: .iso,
            outputURL: output,
            dataDirectory: nil,
            progress: { _ in },
            cancellation: CancellationFlag()
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - 参数校验

    func testFormatExtensionMismatchRejected() throws {
        let directory = try UITestSupport.makeTempDirectory("generate-mismatch")
        defer { UITestSupport.removeQuietly(directory) }

        let service = GenerationService(factory: { family in StubGenerator(family: family) })
        XCTAssertThrowsError(try service.generate(
            project: makeProject(),
            tone: .default,
            image: RasterImage.gray(width: 16, height: 16, value: 0),
            format: .wav,
            outputURL: directory.appendingPathComponent("disc.iso"),
            dataDirectory: nil,
            progress: { _ in },
            cancellation: CancellationFlag()
        ))
    }

    func testWavWithDataDirectoryRejected() throws {
        let directory = try UITestSupport.makeTempDirectory("generate-wav-data")
        defer { UITestSupport.removeQuietly(directory) }

        var project = UITestSupport.sampleProject(family: .cd)
        project.outputs.dataDirectory = directory.path
        let service = GenerationService(factory: { family in StubGenerator(family: family) })
        XCTAssertThrowsError(try service.generate(
            project: project,
            tone: .default,
            image: RasterImage.gray(width: 16, height: 16, value: 0),
            format: .wav,
            outputURL: directory.appendingPathComponent("disc.wav"),
            dataDirectory: directory,
            progress: { _ in },
            cancellation: CancellationFlag()
        ))
    }

    func testOutputURLUsesRequestedFormatExtension() {
        var project = UITestSupport.sampleProject(family: .cd)
        project.outputs.outputPath = "/tmp/example.wav"
        XCTAssertEqual(
            GenerationService.outputURL(for: project, format: .raw).lastPathComponent,
            "example.raw"
        )
        XCTAssertEqual(
            GenerationService.outputURL(for: project, format: .iso).lastPathComponent,
            "example.iso"
        )

        project.outputs.outputPath = ""
        let fallback = GenerationService.outputURL(for: project, format: .iso)
        XCTAssertEqual(fallback.pathExtension, "iso")
        XCTAssertFalse(fallback.lastPathComponent.isEmpty)
    }

    // MARK: - 作业状态机

    @MainActor
    func testGenerationJobSucceeds() async throws {
        let directory = try UITestSupport.makeTempDirectory("job-ok")
        defer { UITestSupport.removeQuietly(directory) }
        let output = directory.appendingPathComponent("disc.iso")

        let service = GenerationService(factory: { family in
            StubGenerator(family: family, byteCount: 1024)
        })
        let job = GenerationJob()
        job.start(
            service: service,
            project: makeProject(),
            tone: .default,
            imageProvider: { RasterImage.gray(width: 32, height: 32, value: 90) },
            format: .iso,
            outputURL: output,
            dataDirectory: nil
        )

        try await UITestSupport.waitUntil {
            if case .succeeded = job.state { return true }
            if case .failed = job.state { return true }
            return false
        }
        guard case .succeeded(let result) = job.state else {
            XCTFail("作业未成功：\(job.state)")
            return
        }
        XCTAssertEqual(result.byteCount, 1024)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(job.outputURL, output)
    }

    @MainActor
    func testGenerationJobFailsWithChineseMessage() async throws {
        let directory = try UITestSupport.makeTempDirectory("job-fail")
        defer { UITestSupport.removeQuietly(directory) }

        let service = GenerationService(factory: { _ in
            throw DiscError.unsupported("模拟：引擎尚未接入")
        })
        let job = GenerationJob()
        job.start(
            service: service,
            project: makeProject(),
            tone: .default,
            imageProvider: { RasterImage.gray(width: 16, height: 16, value: 0) },
            format: .iso,
            outputURL: directory.appendingPathComponent("disc.iso"),
            dataDirectory: nil
        )

        try await UITestSupport.waitUntil {
            if case .failed = job.state { return true }
            return false
        }
        guard case .failed(let message) = job.state else {
            XCTFail("作业未失败：\(job.state)")
            return
        }
        XCTAssertTrue(message.contains("尚未接入"), message)
    }

    @MainActor
    func testResetOnlyWhenNotRunning() {
        let job = GenerationJob()
        job.reset()
        XCTAssertEqual(job.state, .idle)
    }

    // MARK: - 接线

    func testAllThreeEnginesAreWired() {
        let service = GenerationService()
        for family in DiscFamily.allCases {
            XCTAssertTrue(
                service.hasGenerator(for: family),
                "\(family.displayNameZH) 引擎应已接入 GenerationService"
            )
            do {
                let generator = try GenerationService.makeDefaultFactory(family)
                XCTAssertEqual(generator.family, family, "\(family.displayNameZH) 分派到了错误的引擎")
            } catch {
                XCTFail("\(family.displayNameZH) 引擎分派失败：\(error)")
            }
        }
    }

    func testBluRayToneGuard() throws {
        // 蓝光引擎在生成阶段拒绝四阶；UI 侧已经把它夹成两阶，这里只验证工程校验层。
        var project = UITestSupport.sampleProject(family: .bluRay)
        project.tone = ToneProfile(levels: 4)
        XCTAssertThrowsError(try project.validate(), "蓝光工程不应保存四阶影调")
    }
}
