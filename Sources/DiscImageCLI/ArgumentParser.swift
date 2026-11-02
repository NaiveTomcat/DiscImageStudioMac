import DiscImageCore
import Foundation

/// 极简的 `--key value` 参数解析器。
/// 需求足够小，不值得引第三方依赖；未知参数一律报错，避免拼错静默失效。
struct ArgumentParser {
    private var values: [String: String] = [:]
    private var enabledFlags: Set<String> = []
    private let knownValueOptions: Set<String>
    private let knownFlags: Set<String>

    init(arguments: [String], valueOptions: [String], flags: [String]) throws {
        knownValueOptions = Set(valueOptions)
        knownFlags = Set(flags)
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                throw DiscError.unsupported("无法识别的参数：\(argument)")
            }
            let name = String(argument.dropFirst(2))
            if knownFlags.contains(name) {
                enabledFlags.insert(name)
                index += 1
                continue
            }
            guard knownValueOptions.contains(name) else {
                throw DiscError.unsupported("未知选项：--\(name)")
            }
            guard index + 1 < arguments.count else {
                throw DiscError.unsupported("选项 --\(name) 缺少取值")
            }
            values[name] = arguments[index + 1]
            index += 2
        }
    }

    func string(_ name: String) -> String? { values[name] }
    func bool(_ name: String) -> Bool { enabledFlags.contains(name) || values[name] == "true" }

    func requiredString(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else {
            throw DiscError.unsupported("缺少必填选项 --\(name)")
        }
        return value
    }

    func int(_ name: String) -> Int? { values[name].flatMap(Int.init) }
    func double(_ name: String) -> Double? { values[name].flatMap(Double.init) }
}
