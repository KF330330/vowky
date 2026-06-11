import SwiftUI

// MARK: - 双语对照转写视图（原文段 + 译文段交错）

/// 翻译启用时替换转写卡片里的 TextEditor：每段原文下方紧跟弱化样式的译文，
/// partial 段半透明，失败段显示角标 + 重试。
struct BilingualTranscriptView: View {
    @ObservedObject var coordinator: TranslationCoordinator
    let emptyText: String

    /// 当前是否贴底 → 决定新内容到来时是否自动跟随。用户手动上翻离开底部即暂停跟随。
    @State private var isPinnedToBottom = true
    @State private var showJumpButton = false
    /// 底部锚点在命名坐标系内的 maxY 与可视区高度（onPreferenceChange 无法互读，缓存到 State）
    @State private var bottomAnchorMaxY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private static let bottomAnchorID = "bilingual-bottom"
    private static let scrollSpace = "bilingual-scroll"
    /// 锚点底边距可视区底边 ≤ 此值即视为"贴底"。留余量吸收 partial 行每 1.5s 整段替换的高度抖动。
    private static let bottomThreshold: CGFloat = 80

    var body: some View {
        if coordinator.paragraphs.isEmpty {
            Text(emptyText)
                .font(.system(size: 14))
                .foregroundColor(RecordingTheme.textMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(coordinator.paragraphs) { paragraph in
                            BilingualParagraphRow(
                                paragraph: paragraph,
                                onRetry: { coordinator.retry(paragraphID: paragraph.id) }
                            )
                            .id(paragraph.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: BottomDistanceKey.self,
                                        value: geo.frame(in: .named(Self.scrollSpace)).maxY
                                    )
                                }
                            )
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: Self.scrollSpace)
                .overlay(
                    GeometryReader { viewport in
                        Color.clear.preference(
                            key: ViewportHeightKey.self,
                            value: viewport.size.height
                        )
                    }
                )
                .onPreferenceChange(BottomDistanceKey.self) { value in
                    bottomAnchorMaxY = value
                    recomputePinned()
                }
                .onPreferenceChange(ViewportHeightKey.self) { value in
                    viewportHeight = value
                    recomputePinned()
                }
                .onChange(of: coordinator.paragraphs) { _ in
                    // 仅在贴底时跟随；不加动画，避免 1.5s partial 整段替换造成滚动抖动
                    guard isPinnedToBottom else { return }
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .overlay(alignment: .bottomTrailing) {
                    if showJumpButton {
                        JumpToBottomButton {
                            isPinnedToBottom = true
                            showJumpButton = false
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                            }
                        }
                        .padding(.trailing, 14)
                        .padding(.bottom, 12)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func recomputePinned() {
        guard viewportHeight > 0 else { return }
        // anchorMaxY 在 [0, viewportHeight] 附近说明锚点已露出底部；正向超出越多说明离底越远
        let distanceFromBottom = bottomAnchorMaxY - viewportHeight
        let pinned = distanceFromBottom <= Self.bottomThreshold
        if pinned != isPinnedToBottom {
            isPinnedToBottom = pinned
        }
        if showJumpButton == pinned {
            withAnimation(.easeInOut(duration: 0.15)) { showJumpButton = !pinned }
        }
    }
}

private struct BottomDistanceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct JumpToBottomButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(RecordingTheme.accentMain))
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .help("回到最新")
    }
}

private struct BilingualParagraphRow: View {
    let paragraph: TranscriptParagraph
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(paragraph.text)
                .font(.system(size: 14))
                .foregroundColor(RecordingTheme.textPrimary)
                .lineSpacing(4)
                .textSelection(.enabled)
                .opacity(paragraph.isPartial ? 0.6 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)

            translationRow
        }
    }

    @ViewBuilder
    private var translationRow: some View {
        switch paragraph.translation {
        case .translated(let translation):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(RecordingTheme.accentMain.opacity(0.85))
                    .frame(width: 2)
                Text(translation)
                    .font(.system(size: 12.5))
                    .foregroundColor(RecordingTheme.textSecondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .opacity(paragraph.isPartial ? 0.6 : 1)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .pending:
            // partial 段每 1.5s 就被替换，pending 不渲染避免闪烁；已定段显示翻译中
            if !paragraph.isPartial {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("翻译中…")
                        .font(.system(size: 11))
                        .foregroundColor(RecordingTheme.textMuted)
                }
            }

        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(RecordingTheme.warning)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(RecordingTheme.textMuted)
                    .lineLimit(1)
                Button("重试", action: onRetry)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(RecordingTheme.accentDark)
            }

        case .skippedSameLanguage:
            EmptyView()
        }
    }
}

// MARK: - Apple Translation session 宿主（macOS 15+）

#if canImport(Translation)
import Translation

/// 不可见的 0×0 视图，唯一职责是通过 `.translationTask` 向 AppleTranslationProvider
/// 泵入 TranslationSession。目标语言变更 → 重建 configuration → SwiftUI 取消旧
/// task、用新 session 重跑泵循环。
@available(macOS 15.0, *)
struct AppleTranslationHostView: View {
    let provider: AppleTranslationProvider
    @ObservedObject var coordinator: TranslationCoordinator
    let target: TranslationTarget

    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { session in
                // 语言模型未下载时触发系统下载流程；已就绪则为 no-op
                try? await session.prepareTranslation()
                await provider.handleSession(session)
            }
            .onAppear {
                configuration = makeConfiguration()
            }
            .onChange(of: target) { _ in
                configuration = makeConfiguration()
            }
            .onChange(of: coordinator.detectedSourceBCP47) { _ in
                // 自动识别出的原文语言变化 → 重建 session，免去系统弹窗手选源语言
                configuration = makeConfiguration()
            }
            .onDisappear {
                Task { await provider.invalidateSession() }
            }
    }

    private func makeConfiguration() -> TranslationSession.Configuration? {
        // 必须等自动识别出源语言后再建会话：若用 source=nil 激活，系统在文本不足时
        // 会弹出"无法自动检测语言"手选窗口，正是要避免的。未识别出则返回 nil
        // （translationTask 不激活），识别出后由 onChange 触发重建。
        guard let bcp47 = coordinator.detectedSourceBCP47 else { return nil }
        // 源≈目标（如中文会议+中文目标）的 session 每个请求都会失败，不建；
        // coordinator 侧也会把这种场景的段全部跳过。
        guard !TranslationCoordinator.bcp47SameLanguage(bcp47, target.bcp47) else { return nil }
        return TranslationSession.Configuration(
            source: Locale.Language(identifier: bcp47),
            target: Locale.Language(identifier: target.bcp47)
        )
    }
}
#endif
