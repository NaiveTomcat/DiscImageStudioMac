import SwiftUI

/// 统一配色与尺寸。深色「深海」基调 + 小蓝鲸蓝作强调色。
public enum UITheme {
    public static let accent = Color(red: 0.36, green: 0.76, blue: 0.98)
    public static let accentSoft = Color(red: 0.36, green: 0.76, blue: 0.98).opacity(0.16)
    public static let windowBackground = Color(red: 0.055, green: 0.063, blue: 0.08)
    public static let sidebarBackground = Color(red: 0.078, green: 0.09, blue: 0.115)
    public static let panelBackground = Color(red: 0.115, green: 0.13, blue: 0.16)
    public static let panelBorder = Color.white.opacity(0.08)
    public static let canvasBackground = Color(red: 0.035, green: 0.04, blue: 0.05)
    public static let fileRegion = Color(red: 250.0 / 255, green: 204.0 / 255, blue: 21.0 / 255)
    public static let textPrimary = Color.white.opacity(0.92)
    public static let textSecondary = Color.white.opacity(0.62)
    public static let textTertiary = Color.white.opacity(0.4)
    public static let success = Color(red: 0.4, green: 0.85, blue: 0.55)
    public static let warning = Color(red: 0.98, green: 0.75, blue: 0.28)
    public static let danger = Color(red: 0.98, green: 0.42, blue: 0.42)

    public static let cornerRadius: CGFloat = 12
    public static let pagePadding: CGFloat = 24
}
