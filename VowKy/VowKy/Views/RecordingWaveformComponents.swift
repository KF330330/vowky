import AppKit
import SwiftUI

// MARK: - Recording Visual Components

struct RecordingPulseIcon: View {
    let state: RecordingTranscriptionState
    let level: Float
    let reduceMotion: Bool

    private var normalizedLevel: CGFloat {
        CGFloat(min(max(level, 0), 1))
    }

    var body: some View {
        ZStack {
            if state == .recording && !reduceMotion {
                Circle()
                    .fill(TranscriptionTheme.recordingRed.opacity(0.12))
                    .frame(width: 68, height: 68)
                    .scaleEffect(1 + normalizedLevel * 0.35)
                    .animation(.easeOut(duration: 0.16), value: normalizedLevel)
            }

            Circle()
                .fill(
                    LinearGradient(
                        colors: [TranscriptionTheme.accentBright, TranscriptionTheme.accentMain],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 52, height: 52)
                .shadow(color: TranscriptionTheme.accentMain.opacity(0.24), radius: 12, x: 0, y: 6)

            stateIcon
        }
        .frame(width: 70, height: 70)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch state {
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(TranscriptionTheme.accentDarkest)
        case .cancelled:
            Image(systemName: "xmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(TranscriptionTheme.accentDarkest)
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(TranscriptionTheme.accentDarkest)
        default:
            Image(nsImage: Self.butterflyLargeImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                .foregroundColor(TranscriptionTheme.accentDarkest)
        }
    }

    private static let butterflyLargeImage: NSImage = {
        let img = NSImage(named: "ButterflyLarge") ?? NSImage()
        img.isTemplate = true
        return img
    }()
}

struct RecordingWaveformView: View {
    let bands: [RecordingWaveformBand]
    let isActive: Bool
    let isProcessing: Bool

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            var centerLine = Path()
            centerLine.move(to: CGPoint(x: 0, y: midY))
            centerLine.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(
                centerLine,
                with: .color(TranscriptionTheme.border.opacity(isActive ? 0.72 : 0.45)),
                lineWidth: 1
            )

            guard !bands.isEmpty else { return }

            let usableHeight = max(8, size.height - 8)
            let halfHeight = usableHeight / 2
            let step = bands.count > 1
                ? size.width / CGFloat(bands.count - 1)
                : size.width
            let barWidth = max(2, min(4.5, step * 0.44))
            let style = StrokeStyle(lineWidth: barWidth, lineCap: .round)
            let gradient = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [TranscriptionTheme.accentDeep, TranscriptionTheme.accentBright]),
                startPoint: CGPoint(x: 0, y: size.height),
                endPoint: CGPoint(x: 0, y: 0)
            )

            for (index, band) in bands.enumerated() {
                let positive = CGFloat(min(max(band.positive, 0), 1))
                let negative = CGFloat(min(max(band.negative, 0), 1))
                let x = CGFloat(index) * step
                let top = midY - max(0.75, positive * halfHeight)
                let bottom = midY + max(0.75, negative * halfHeight)

                var bar = Path()
                bar.move(to: CGPoint(x: x, y: top))
                bar.addLine(to: CGPoint(x: x, y: bottom))
                context.opacity = opacity(for: band)
                context.stroke(bar, with: gradient, style: style)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(TranscriptionTheme.secondaryBackground.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(TranscriptionTheme.borderLight, lineWidth: 1)
                )
        )
    }

    private func opacity(for band: RecordingWaveformBand) -> Double {
        if isActive { return 0.95 }
        if isProcessing { return 0.58 }
        return (band.positive > 0 || band.negative > 0) ? 0.46 : 0.30
    }
}

