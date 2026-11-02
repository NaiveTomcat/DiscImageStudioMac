import DiscImageCore
import Foundation

/// `discimage-cli` 入口。
///
/// 用法：
/// ```
/// discimage-cli generate --family dvd --image in.png --out out.iso
/// discimage-cli presets --family cd
/// discimage-cli geometry --family dvd --preset dvd-5-120mm
/// discimage-cli info
/// ```
func printUsage() {
    let usage = """
    discimage-cli —— Disc Image Studio 命令行前端

    子命令：
      generate   把图片（可选再加一个文件夹）编码成盘片镜像
      presets    列出内置盘片预设
      geometry   打印某个盘片几何的关键参数（总长、螺距、圈数）
      info       打印构建信息

    generate 选项：
      --family cd|dvd|bd          介质（必填）
      --image PATH               源图片（可省略，省略时用全黑画布）
      --out PATH                 输出文件（必填）
      --format iso|wav|raw       输出格式（默认 iso；CD 可选 wav / raw）
      --preset ID                使用内置预设（与手工半径二选一）
      --inner MM / --outer MM / --sectors N / --velocity MMPS / --bit-length NM
                                 手工几何参数
      --dither 0..100            抖动强度百分比（默认 75）
      --levels 2|4               灰阶层数（CD 可为 4）
      --brightness -64..64       亮度偏移
      --srgb                     启用 sRGB 反伽马线性化
      --data-dir PATH            数据盘模式：写入该文件夹
      --outer-ring               文件区放在外圈
      --label NAME               卷标
      --size PX                  无图时的画布边长（默认 2048）
      --quiet                    不打印进度

    示例：
      discimage-cli generate --family dvd --preset dvd-5-120mm --image photo.png --out out.iso
      discimage-cli generate --family cd --preset cd-80 --image photo.png --format wav --out art.wav
    """
    FileHandle.standardOutput.write(Data(usage.utf8))
}

func main() -> Int32 {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        printUsage()
        return 1
    }
    arguments.removeFirst()

    do {
        switch command {
        case "generate":
            try runGenerate(arguments)
        case "presets":
            runPresets(arguments)
        case "geometry":
            try runGeometry(arguments)
        case "info", "--version", "-v":
            printInfo()
        case "help", "--help", "-h":
            printUsage()
        default:
            FileHandle.standardError.write(Data("未知子命令：\(command)\n\n".utf8))
            printUsage()
            return 1
        }
        return 0
    } catch let error as DiscError {
        FileHandle.standardError.write(Data("错误：\(error.errorDescription ?? "未知错误")\n".utf8))
        return 1
    } catch is CancellationError {
        FileHandle.standardError.write(Data("已取消\n".utf8))
        return 130
    } catch {
        FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8))
        return 1
    }
}

exit(main())
