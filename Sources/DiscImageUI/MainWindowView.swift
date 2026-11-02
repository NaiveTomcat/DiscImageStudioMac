import DiscImageCore
import SwiftUI

/// 应用主窗口入口。工作包 D 会把这里替换成真正的五工作区外壳。
public struct MainWindowView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            Text("Disc Image Studio")
                .font(.largeTitle.weight(.semibold))
            Text("界面正在接入（工作包 D）")
                .foregroundStyle(.secondary)
            Text("引擎版本 \(DiscImageCore.version)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
