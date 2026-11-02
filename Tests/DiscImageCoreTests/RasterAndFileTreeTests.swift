import Foundation
import XCTest
@testable import DiscImageCore

final class RasterImageTests: XCTestCase {

    func testGrayLuminance() {
        let image = RasterImage.gray(width: 4, height: 3, value: 200)
        XCTAssertEqual(image.luminance(x: 0, y: 0), 200, accuracy: 0.5)
        // 越界夹紧到边缘，不崩溃
        XCTAssertEqual(image.luminance(x: -5, y: 99), 200, accuracy: 0.5)
        XCTAssertEqual(image.luminance(bilinearX: 1.5, bilinearY: 1.5), 200, accuracy: 0.5)
    }

    func testPremultipliedAlphaIsTreatedAsCompositedOnBlack() {
        // 预乘：50% 白 = (128,128,128,128)，与黑底合成后亮度应为 ~128
        let pixels: [UInt8] = [128, 128, 128, 128]
        let image = RasterImage(width: 1, height: 1, pixels: pixels)
        XCTAssertEqual(image.luminance(x: 0, y: 0), 128, accuracy: 0.5)
    }

    func testBlackImageIsZero() {
        let image = RasterImage.black(width: 8, height: 8)
        XCTAssertEqual(image.luminance(x: 3, y: 3), 0, accuracy: 1e-9)
    }

    func testScalingKeepsAspectRatio() {
        let image = RasterImage.gray(width: 400, height: 200, value: 10)
        let scaled = image.scaled(maxDimension: 100)
        XCTAssertEqual(scaled.width, 100)
        XCTAssertEqual(scaled.height, 50)
        // 已经够小的图原样返回
        XCTAssertEqual(scaled.scaled(maxDimension: 1000).width, 100)
    }

    func testScalingPreservesValue() {
        let image = RasterImage.gray(width: 64, height: 64, value: 77)
        let scaled = image.scaled(maxDimension: 16)
        XCTAssertEqual(scaled.luminance(x: 5, y: 9), 77, accuracy: 0.6)
    }

    func testOpaqueBinaryGrayscaleDetection() {
        XCTAssertTrue(RasterImage.gray(width: 2, height: 2, value: 0).isOpaqueBinaryGrayscale == false)
        var pixels: [UInt8] = []
        for value: UInt8 in [0, 255, 255, 0] {
            pixels += [value, value, value, 255]
        }
        XCTAssertTrue(RasterImage(width: 2, height: 2, pixels: pixels).isOpaqueBinaryGrayscale)
        // 半透明会让检测失败（盘面要看合成后的亮度，不是原色）
        var translucent: [UInt8] = []
        for _ in 0..<4 { translucent += [0, 0, 0, 128] }
        XCTAssertFalse(RasterImage(width: 2, height: 2, pixels: translucent).isOpaqueBinaryGrayscale)
    }

    func testPNGRoundTripThroughImageIO() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscImageCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var pixels: [UInt8] = []
        for index in 0..<(4 * 4) {
            let value = UInt8((index * 16) % 256)
            pixels += [value, value, value, 255]
        }
        let original = RasterImage(width: 4, height: 4, pixels: pixels)
        let url = directory.appendingPathComponent("test.png")
        try original.writePNG(to: url)

        let loaded = try RasterImage.load(contentsOf: url)
        XCTAssertEqual(loaded.width, 4)
        XCTAssertEqual(loaded.height, 4)
        for y in 0..<4 {
            for x in 0..<4 {
                XCTAssertEqual(loaded.luminance(x: x, y: y),
                               original.luminance(x: x, y: y),
                               accuracy: 1.5,
                               "像素 (\(x),\(y)) 往返后不一致")
            }
        }
    }
}

final class FileTreeTests: XCTestCase {

    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscImageCoreTree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data(repeating: 7, count: 100).write(to: root.appendingPathComponent("sub/b.bin"))
        return root
    }

    func testScanFindsFilesAndDirectories() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let entries = try FileTree.scan(root: root)
        let paths = entries.map(\.relativePath)
        XCTAssertTrue(paths.contains("a.txt"))
        XCTAssertTrue(paths.contains("sub"))
        XCTAssertTrue(paths.contains("sub/b.bin"))
        XCTAssertEqual(FileTree.totalBytes(entries), 105)

        let filesOnly = try FileTree.scan(root: root, includeDirectories: false)
        XCTAssertEqual(filesOnly.map(\.relativePath), ["a.txt", "sub/b.bin"])
    }

    func testScanIsSortedDeterministically() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try FileTree.scan(root: root).map(\.relativePath)
        let second = try FileTree.scan(root: root).map(\.relativePath)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, first.sorted())
    }

    func testScanRejectsSymbolicLinks() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))

        XCTAssertThrowsError(try FileTree.scan(root: root)) { error in
            guard case DiscError.io(let message) = error else {
                return XCTFail("应是 io 错误，实际 \(error)")
            }
            XCTAssertTrue(message.contains("符号链接"))
        }
    }

    func testScanMissingFolderThrowsMissingPayload() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscImageCoreMissing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertThrowsError(try FileTree.scan(root: missing)) { error in
            guard case DiscError.missingPayload = error else {
                return XCTFail("应是 missingPayload，实际 \(error)")
            }
        }
    }
}
