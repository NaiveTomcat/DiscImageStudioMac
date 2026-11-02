import AppKit
import DiscImageCore
import DiscImageUI
import SwiftUI

/// 应用薄壳：只负责建立窗口与菜单，真内容全在 `DiscImageUI`。
///
/// 注意：`@main` 只在 App target 里出现一次，别在 UI target 里再加。
@main
struct DiscImageStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Disc Image Studio") {
            MainWindowView()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("打开工程…") {
                    NotificationCenter.default.post(name: .discImageStudioOpenProject, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = nil
        // 命令行的 stdout 在 GUI 里没有终端，出错时至少能在控制台看到。
        setvbuf(stdout, nil, _IOLBF, 0)
    }
}

extension Notification.Name {
    /// 菜单「打开工程…」→ UI 层处理。
    static let discImageStudioOpenProject = Notification.Name("DiscImageStudio.openProject")
}
