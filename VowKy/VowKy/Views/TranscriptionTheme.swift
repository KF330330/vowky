import SwiftUI

// MARK: - 转写窗口共享视觉系统
//
// 文件转写（FileTranscriptionView）与录音转写（RecordingTranscriptionView）共用的
// 米绿主题色板、按钮样式与卡片修饰器。此前两个视图各持一份逐字节相同的拷贝（约 250 行），
// 2026-07-04 合并至此，作为唯一来源。

enum TranscriptionTheme {
    static let background = color(0xF7FAF0)
    static let secondaryBackground = color(0xF0F5E4)
    static let cardBackground = color(0xFFFFFF)
    static let elevatedBackground = color(0xE8EED8)
    static let textPrimary = color(0x1A2210)
    static let textSecondary = color(0x4E5C3A)
    static let textMuted = color(0x8A9872)
    static let accentBright = color(0xD4E87C)
    static let accentMain = color(0xB8D458)
    static let accentDeep = color(0x8AAE3A)
    static let accentDark = color(0x5A6B2A)
    static let accentDarkest = color(0x4A5A22)
    static let border = color(0xDCE6C8)
    static let borderLight = color(0xE8EED8)
    static let error = color(0xD8544C)
    static let recordingRed = color(0xEF6159)
    static let warning = color(0xC88A2A)
    static let shadow = color(0x4A5A22, opacity: 0.10)

    private static func color(_ hex: UInt32, opacity: Double = 1) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}

// MARK: - Button Styles

struct TranscriptionPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(TranscriptionTheme.accentDarkest)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: isEnabled
                                ? [TranscriptionTheme.accentBright, TranscriptionTheme.accentMain]
                                : [TranscriptionTheme.borderLight, TranscriptionTheme.border],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(
                        color: isEnabled ? TranscriptionTheme.accentMain.opacity(configuration.isPressed ? 0.10 : 0.24) : .clear,
                        radius: configuration.isPressed ? 3 : 8,
                        x: 0,
                        y: configuration.isPressed ? 1 : 3
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.55)
    }
}

struct TranscriptionSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(TranscriptionTheme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(TranscriptionTheme.cardBackground.opacity(isEnabled ? 0.92 : 0.54))
                    .overlay(
                        Capsule()
                            .stroke(TranscriptionTheme.border, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.52)
    }
}

struct TranscriptionGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(TranscriptionTheme.textMuted)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(configuration.isPressed ? TranscriptionTheme.borderLight.opacity(0.6) : Color.clear)
            )
            .opacity(isEnabled ? 1 : 0.5)
    }
}

struct TranscriptionIconButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(tint)
            .frame(width: 24, height: 24)
            .background(
                Circle()
                    .fill(TranscriptionTheme.cardBackground.opacity(isEnabled ? 0.86 : 0.32))
                    .overlay(
                        Circle()
                            .stroke(TranscriptionTheme.border.opacity(0.82), lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.40)
    }
}

// MARK: - Card Modifier

struct TranscriptionCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(TranscriptionTheme.cardBackground.opacity(0.96))
                    .shadow(color: TranscriptionTheme.shadow, radius: 18, x: 0, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(TranscriptionTheme.borderLight, lineWidth: 1)
            )
    }
}

extension View {
    func transcriptionCardStyle() -> some View {
        modifier(TranscriptionCardModifier())
    }
}
