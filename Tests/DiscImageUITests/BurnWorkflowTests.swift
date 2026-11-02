import DiscImageCore
import DiscImageUI
import XCTest

/// 刻录页状态机：枚举 → 空白检查 → 二次确认 → 进度/取消。
///
/// 本机没有刻录机，全部走 `MockBurnAdapter`（包装工作包 E 的 `MockBurnService`），
/// **不会启动任何子进程、不会真烧盘**。
@MainActor
final class BurnWorkflowTests: XCTestCase {
    private func makeImageFile(in directory: URL, name: String = "disc.iso") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        return url
    }

    func testScanFindsBlankDevice() throws {
        let adapter = MockBurnAdapter()
        let workflow = BurnWorkflow(service: adapter)

        workflow.refreshDevices()

        XCTAssertEqual(workflow.phase, .ready)
        XCTAssertGreaterThanOrEqual(workflow.devices.count, 1)
        XCTAssertEqual(workflow.selectedDeviceID, workflow.devices.first?.id)
        XCTAssertTrue(workflow.mediaStatus.isBlank, "默认模拟介质应是空白盘")
        XCTAssertEqual(workflow.selectedSpeed, .automatic)
        XCTAssertEqual(adapter.burnCallCount, 0, "枚举阶段绝不能发生刻录")
    }

    func testNoDevicesShowsFailedState() {
        let workflow = BurnWorkflow(service: MockBurnAdapter.noDevices())

        workflow.refreshDevices()

        XCTAssertTrue(workflow.devices.isEmpty)
        guard case .failed(let message) = workflow.phase else {
            XCTFail("应是失败状态，实际 \(workflow.phase)")
            return
        }
        XCTAssertTrue(message.contains("没有检测到刻录机"), message)
    }

    func testPrepareRequiresExistingImage() throws {
        let directory = try UITestSupport.makeTempDirectory("burn-missing-image")
        defer { UITestSupport.removeQuietly(directory) }

        let adapter = MockBurnAdapter()
        let workflow = BurnWorkflow(service: adapter)
        workflow.refreshDevices()

        let missing = directory.appendingPathComponent("not-here.iso")
        XCTAssertThrowsError(try workflow.prepareBurn(imageURL: missing, format: .iso)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("找不到"), message)
        }
        guard case .failed = workflow.phase else {
            XCTFail("镜像缺失应进入失败状态")
            return
        }
        XCTAssertEqual(adapter.burnCallCount, 0)
        XCTAssertNil(workflow.pendingRequest)
    }

    func testPrepareDoesNotBurnUntilConfirmed() throws {
        let directory = try UITestSupport.makeTempDirectory("burn-confirm")
        defer { UITestSupport.removeQuietly(directory) }
        let image = try makeImageFile(in: directory)

        let adapter = MockBurnAdapter()
        let workflow = BurnWorkflow(service: adapter)
        workflow.refreshDevices()

        try workflow.prepareBurn(imageURL: image, format: .iso, volumeLabel: "WHALE")

        guard case .needsConfirmation(let request) = workflow.phase else {
            XCTFail("应等待二次确认，实际 \(workflow.phase)")
            return
        }
        XCTAssertEqual(request.imageURL, image)
        XCTAssertEqual(request.mediaKind, .data)
        XCTAssertEqual(request.volumeLabel, "WHALE")
        XCTAssertEqual(adapter.burnCallCount, 0, "确认之前绝不能刻录")
        XCTAssertNil(adapter.lastBurnURL)

        XCTAssertTrue(workflow.confirmationMessage.contains("刻录"))
        XCTAssertTrue(workflow.confirmationMessage.contains("报废"))
    }

    func testConfirmBurnPerformsBurn() async throws {
        let directory = try UITestSupport.makeTempDirectory("burn-success")
        defer { UITestSupport.removeQuietly(directory) }
        let image = try makeImageFile(in: directory)

        let adapter = MockBurnAdapter()
        let workflow = BurnWorkflow(service: adapter)
        workflow.refreshDevices()
        try workflow.prepareBurn(imageURL: image, format: .wav)
        XCTAssertEqual(workflow.pendingRequest?.mediaKind, .audio)

        await workflow.confirmAndBurn()

        guard case .finished(let message) = workflow.phase else {
            XCTFail("应刻录完成，实际 \(workflow.phase)")
            return
        }
        XCTAssertTrue(message.contains("模拟"))
        XCTAssertEqual(adapter.burnCallCount, 1)
        XCTAssertEqual(adapter.lastBurnURL, image)
        XCTAssertNil(workflow.pendingRequest)
    }

    func testNonBlankMediaIsRejectedBeforeBurn() throws {
        let directory = try UITestSupport.makeTempDirectory("burn-nonblank")
        defer { UITestSupport.removeQuietly(directory) }
        let image = try makeImageFile(in: directory)

        let adapter = MockBurnAdapter.nonBlankDisc()
        let workflow = BurnWorkflow(service: adapter)
        workflow.refreshDevices()

        XCTAssertFalse(workflow.mediaStatus.isBlank)
        XCTAssertThrowsError(try workflow.prepareBurn(imageURL: image, format: .iso)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("不是空白"), message)
        }
        guard case .failed = workflow.phase else {
            XCTFail("非空白介质应进入失败状态")
            return
        }
        XCTAssertEqual(adapter.burnCallCount, 0)
    }

    func testBackendFailureSurfacesMessage() async throws {
        let directory = try UITestSupport.makeTempDirectory("burn-backend-fail")
        defer { UITestSupport.removeQuietly(directory) }
        let image = try makeImageFile(in: directory)

        let workflow = BurnWorkflow(service: MockBurnAdapter.failingBurn())
        workflow.refreshDevices()
        try workflow.prepareBurn(imageURL: image, format: .iso)

        await workflow.confirmAndBurn()

        guard case .failed(let message) = workflow.phase else {
            XCTFail("后端失败应进入失败状态，实际 \(workflow.phase)")
            return
        }
        XCTAssertTrue(message.contains("模拟刻录失败"), message)
    }

    func testCancellationBeforeBurnDoesNotTouchDisc() throws {
        let directory = try UITestSupport.makeTempDirectory("burn-cancel")
        defer { UITestSupport.removeQuietly(directory) }
        let image = try makeImageFile(in: directory)

        let adapter = MockBurnAdapter()
        let cancellation = CancellationFlag()
        cancellation.cancel()
        let request = BurnJobRequest(
            imageURL: image,
            mediaKind: .data,
            deviceID: "1"
        )
        let outcome = try adapter.burn(
            request,
            progress: { _ in },
            cancellation: cancellation
        )
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(adapter.burnCallCount, 0, "已取消的请求不应调用后端")
    }

    func testMediaKindMapping() {
        XCTAssertEqual(BurnWorkflow.mediaKind(for: .wav), .audio)
        XCTAssertEqual(BurnWorkflow.mediaKind(for: .raw), .audio)
        XCTAssertEqual(BurnWorkflow.mediaKind(for: .iso), .data)
    }

    func testUnavailableServiceReportsChineseReason() {
        let workflow = BurnWorkflow(service: UnavailableBurnService())
        workflow.refreshDevices()
        guard case .failed(let message) = workflow.phase else {
            XCTFail("未接入的刻录服务应进入失败状态")
            return
        }
        XCTAssertTrue(message.contains("工作包 E") || message.contains("尚未接入"), message)
    }

    func testResetPhaseAfterFinish() async throws {
        let directory = try UITestSupport.makeTempDirectory("burn-reset")
        defer { UITestSupport.removeQuietly(directory) }
        let image = try makeImageFile(in: directory)

        let workflow = BurnWorkflow(service: MockBurnAdapter())
        workflow.refreshDevices()
        try workflow.prepareBurn(imageURL: image, format: .iso)
        await workflow.confirmAndBurn()
        guard case .finished = workflow.phase else {
            XCTFail("应先完成")
            return
        }
        workflow.resetPhase()
        XCTAssertEqual(workflow.phase, .ready)
    }
}
