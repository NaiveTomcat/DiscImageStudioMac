import Foundation

/// 共享层版本标识（`discimage-cli info` 会打印）。
public enum DiscImageCore {
    public static let version = "0.1.2"
    /// 工程文件 schema 版本（`.discproj`）。
    public static let projectSchemaVersion = 2
    /// 蓝光 sidecar 的格式标识。
    public static let bluRaySidecarSchema = "bd-r-image-v1"
}
