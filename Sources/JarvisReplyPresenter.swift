import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class JarvisReplyPresenter {
    static let shared = JarvisReplyPresenter()

    private let panelSize = CGSize(width: 430, height: 190)
    private let horizontalMargin: CGFloat = 24
    private let verticalMargin: CGFloat = 132
    private let fadeAnimationDuration: TimeInterval = 0.22

    private let state = JarvisReplyPreviewState()
    private var speechService: JarvisReplySpeechService?
    private weak var overlayManager: (any RecordingOverlaySurface)?
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    private init() {
    }

    private func makeSpeechServiceIfNeeded() -> JarvisReplySpeechService {
        if let speechService { return speechService }
        let speechService = JarvisReplySpeechService()
        speechService.onSpeakingChanged = { [weak self] isSpeaking in
            Task { @MainActor in
                self?.overlayManager?.setJarvisSpeaking(isSpeaking)
            }
        }
        self.speechService = speechService
        return speechService
    }

    func start(overlayManager: any RecordingOverlaySurface) {
        self.overlayManager = overlayManager
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: TranscriptRouter.chatTurn,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let role = note.userInfo?["role"] as? String,
                  let text = note.userInfo?["text"] as? String else { return }
            Task { @MainActor in
                self?.handleChatTurn(role: role, text: text)
            }
        }
    }

    private func handleChatTurn(role: String, text: String) {
        switch role {
        case "JARVIS-final":
            overlayManager?.setJarvisSending(false)
            showReply(text)
        case "JARVIS-timeout", "JARVIS-error":
            overlayManager?.setJarvisSending(false)
            showStatus(text)
        default:
            break
        }
    }

    private func showReply(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        showPanel(title: "JARVIS", text: trimmed, isError: false, duration: visibleDuration(for: trimmed))
        makeSpeechServiceIfNeeded().speakTail(of: trimmed)
    }

    private func showStatus(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.isEmpty ? "No JARVIS reply captured. Check the JARVIS drawer." : trimmed
        speechService?.stop()
        showPanel(title: "JARVIS", text: message, isError: true, duration: 7.0)
    }

    private func showPanel(title: String, text: String, isError: Bool, duration: TimeInterval) {
        state.title = title
        state.text = text
        state.isError = isError
        state.isVisible = false

        let panel = ensurePanel()
        panel.orderFrontRegardless()

        withAnimation(.easeOut(duration: fadeAnimationDuration)) {
            state.isVisible = true
        }

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: fadeAnimationDuration)) {
                self.state.isVisible = false
            }
            try? await Task.sleep(for: .seconds(fadeAnimationDuration))
            guard !Task.isCancelled else { return }
            if !self.state.isVisible {
                self.panel?.orderOut(nil)
            }
        }

        panel.setFrame(adjustedPanelFrame(), display: true)
    }

    private func visibleDuration(for text: String) -> TimeInterval {
        let scaled = Double(text.count) / 42.0
        return min(18.0, max(8.0, scaled))
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let frame = adjustedPanelFrame()
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: JarvisReplyPreviewCard(state: state))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting

        self.panel = panel
        panel.setFrame(frame, display: true)
        return panel
    }

    private func adjustedPanelFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? .init(x: 0, y: 0, width: 1024, height: 768)
        let x = visibleFrame.maxX - panelSize.width - horizontalMargin
        let y = visibleFrame.maxY - panelSize.height - verticalMargin
        return NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
    }
}

final class JarvisReplySpeechService: NSObject, AVSpeechSynthesizerDelegate {
    var onSpeakingChanged: ((Bool) -> Void)?

    private lazy var synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        return synthesizer
    }()
    private weak var activeUtterance: AVSpeechUtterance?

    override init() {
        super.init()
    }

    func speakTail(of reply: String) {
        let tail = Self.spokenTail(from: reply)
        guard !tail.isEmpty else { return }

        stop()

        let utterance = AVSpeechUtterance(string: tail)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        utterance.rate = 0.48
        utterance.pitchMultiplier = 0.95
        utterance.volume = 1.0
        activeUtterance = utterance
        onSpeakingChanged?(true)
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if activeUtterance == nil {
            onSpeakingChanged?(false)
        }
    }

    static func spokenTail(from reply: String, maxSentences: Int = 2) -> String {
        let cleaned = cleanForSpeech(reply)
        guard !cleaned.isEmpty else { return "" }

        let sentences = splitSentences(cleaned)
        if sentences.count > 1 {
            return clampForSpeech(sentences.suffix(maxSentences).joined(separator: " "))
        }

        if let sentence = sentences.last, sentence.count <= 260 {
            return sentence
        }

        let lines = cleaned
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.count > 1 {
            return clampForSpeech(lines.suffix(maxSentences).joined(separator: " "))
        }

        return clampForSpeech(cleaned)
    }

    private static func cleanForSpeech(_ text: String) -> String {
        var cleaned = text
        let markdownTokens = ["```", "`", "**", "__", "###", "##", "#", ">"]
        for token in markdownTokens {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        cleaned = cleaned.replacingOccurrences(of: "\\[[^\\]]+\\]\\([^\\)]+\\)", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let delimiters = Set<Character>(".!?。！？")

        for character in text {
            current.append(character)
            if delimiters.contains(character) {
                appendSentence(current, to: &sentences)
                current = ""
            }
        }
        appendSentence(current, to: &sentences)
        return sentences
    }

    private static func appendSentence(_ sentence: String, to sentences: inout [String]) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .alphanumerics) != nil else { return }
        sentences.append(trimmed)
    }

    private static func clampForSpeech(_ text: String, maxCharacters: Int = 320) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        var selectedWords: [Substring] = []
        var count = 0
        for word in trimmed.split(separator: " ").reversed() {
            let nextCount = count + word.count + (selectedWords.isEmpty ? 0 : 1)
            guard nextCount <= maxCharacters else { break }
            selectedWords.append(word)
            count = nextCount
        }
        return selectedWords.reversed().joined(separator: " ")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishIfActive(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishIfActive(utterance)
    }

    private func finishIfActive(_ utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, utterance === self.activeUtterance else { return }
            self.activeUtterance = nil
            self.onSpeakingChanged?(false)
        }
    }
}

private final class JarvisReplyPreviewState: ObservableObject {
    @Published var title = "JARVIS"
    @Published var text = ""
    @Published var isVisible = false
    @Published var isError = false
}

private struct JarvisReplyPreviewCard: View {
    @ObservedObject var state: JarvisReplyPreviewState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: state.isError ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state.isError ? Color.orange : Color.purple.opacity(0.95))
                Text(state.title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.82))
                Spacer()
            }

            Text(state.text)
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(7)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke((state.isError ? Color.orange : Color.purple).opacity(0.35), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.42), radius: 14, y: 5)
        )
        .opacity(state.isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: state.isVisible)
        .padding(4)
    }
}
