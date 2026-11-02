import DiscImageCore
import Foundation

/// 引擎分发。
///
/// 每个介质 target 导出 `<Family>ImageGenerator: DiscImageGenerator`。
/// 三个工作包落地前，这里保持最小实现：未知介质一律明确报错，
/// 而不是静默生成空文件。
func generator(for family: DiscFamily) throws -> DiscImageGenerator {
    throw DiscError.unsupported("\(family.displayNameZH) 引擎尚未接入（工作包 A/B/C 落地后由 lead 接线）")
}
