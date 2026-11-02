import DiscImageBluRay
import DiscImageCd
import DiscImageCore
import DiscImageDvd
import Foundation

/// 引擎分发：把 `DiscFamily` 映射到对应介质 target 的公开入口。
///
/// 三个 target 各自导出一个 `DiscImageGenerator` 实现，这里只做一一对应，
/// 不含任何编码逻辑——保证 CLI 与 UI 走同一条链路。
func generator(for family: DiscFamily) throws -> DiscImageGenerator {
    switch family {
    case .cd: return CdImageGenerator()
    case .dvd: return DvdImageGenerator()
    case .bluRay: return BluRayImageGenerator()
    }
}
