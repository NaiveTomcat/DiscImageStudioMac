import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 文件导出用的内存文档（工程另存为、PNG 快照）。
public struct DataFileDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.json, .png, .data] }
    public static var writableContentTypes: [UTType] { [.json, .png, .data] }

    public var data: Data

    public init(data: Data) {
        self.data = data
    }

    public init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

public enum ProjectFileTypes {
    /// `.discproj`：JSON 结构，导出时优先用这个动态类型。
    public static let project: UTType =
        UTType(exportedAs: "com.discimagestudio.discproj", conformingTo: .json)
}
