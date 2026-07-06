import Foundation
import Observation

// MARK: - VoiceLoopController

/// Hands-free conversation loop: listen → send → speak → listen again.
/// Every state change goes through `transition`/the generation counter below —
/// STOP/Esc bumps `generation`, which makes any in-flight step in `runLoop`
/// bail out on its next check instead of racing a fresh `start()`.
///
/// The mic and TTS are strictly mutually exclusive: `listening` only runs
/// while `SpeechRecognizer` is active, `speaking` only starts after the mic
/// has been stopped, so the app never "hears" its own voice.
@MainActor
@Observable
final class VoiceLoopController {

    enum State: Equatable {
        case idle
        case listening
        case thinking
        case speaking
    }

    private(set) var state: State = .idle

    var isActive: Bool { state != .idle }

    private let chatState: ChatState
    private let recognizer = SpeechRecognizer()

    private var generation = 0
    private var loopTask: Task<Void, Never>?
    private var lastPartialAt: ContinuousClock.Instant = .now

    init(chatState: ChatState) {
        self.chatState = chatState
        recognizer.onPartialResult = { [weak self] in
            self?.lastPartialAt = .now
        }
    }

    func start() {
        guard state == .idle else { return }
        generation += 1
        let myGeneration = generation
        loopTask = Task { await self.runLoop(generation: myGeneration) }
    }

    /// STOP button / Esc / conversation switch. Tears everything down
    /// synchronously so nothing keeps listening or talking after this returns.
    func stop() {
        guard state != .idle else { return }
        generation += 1
        loopTask?.cancel()
        recognizer.stop()
        chatState.speechSynthesizer.stopAll()
        state = .idle
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation && !Task.isCancelled
    }

    private func runLoop(generation: Int) async {
        while isCurrent(generation) {
            state = .listening
            let transcript = await listenForUtterance(generation: generation)
            guard isCurrent(generation) else { return }

            guard !transcript.isEmpty else {
                // Nothing said — brief cooldown before restarting the audio
                // engine (pitfall: AVAudioEngine dislikes rapid stop/start).
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }

            state = .thinking
            chatState.draft = transcript
            await chatState.send()
            guard isCurrent(generation) else { return }

            state = .speaking
            if let reply = chatState.messages.last(where: { $0.role == .assistant })?.content,
               !reply.isEmpty {
                chatState.readMessageAloud(reply)
                while chatState.speechSynthesizer.isSpeaking {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard isCurrent(generation) else { return }
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Records until 1.8s pass without a new partial result, or a hard 30s
    /// cap is hit — whichever comes first. Returns the trimmed transcript
    /// (possibly empty if the user said nothing).
    private func listenForUtterance(generation: Int) async -> String {
        lastPartialAt = .now
        await recognizer.start()
        guard isCurrent(generation) else { return "" }

        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while isCurrent(generation) {
            if ContinuousClock.now >= deadline { break }
            if ContinuousClock.now - lastPartialAt >= .milliseconds(1800) { break }
            try? await Task.sleep(for: .milliseconds(150))
        }

        let result = recognizer.transcript
        recognizer.stop()
        guard isCurrent(generation) else { return "" }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
