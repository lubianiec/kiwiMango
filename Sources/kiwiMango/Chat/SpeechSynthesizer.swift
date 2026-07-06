import AVFoundation
import Observation

// MARK: - SpeechSynthesizer

/// Polish text-to-speech for reading assistant replies aloud. Thin wrapper
/// around `AVSpeechSynthesizer` — queues utterances, tracks whether anything
/// is still queued/playing via a small delegate relay (same pattern as
/// `TerminationRelay` in AgentManager: the delegate protocol needs a
/// non-isolated `NSObject`, so it hops back onto the main actor itself).
@MainActor
@Observable
final class SpeechSynthesizer: NSObject {

    private(set) var isSpeaking = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var pendingCount = 0
    @ObservationIgnored private lazy var relay = SpeechDelegateRelay(owner: self)

    override init() {
        super.init()
        synthesizer.delegate = relay
    }

    /// Enqueues text to be spoken. Empty/whitespace-only text is a no-op.
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "pl-PL")
        pendingCount += 1
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Clears the whole queue immediately (new message, regenerate, or
    /// switching conversation — see PLAN.md F7.1 pitfall).
    func stopAll() {
        synthesizer.stopSpeaking(at: .immediate)
        pendingCount = 0
        isSpeaking = false
    }

    fileprivate func utteranceFinished() {
        pendingCount = max(0, pendingCount - 1)
        isSpeaking = pendingCount > 0
    }
}

// MARK: - SpeechDelegateRelay

private final class SpeechDelegateRelay: NSObject, AVSpeechSynthesizerDelegate {
    weak var owner: SpeechSynthesizer?

    init(owner: SpeechSynthesizer) {
        self.owner = owner
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [owner] in owner?.utteranceFinished() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [owner] in owner?.utteranceFinished() }
    }
}

// MARK: - StreamingSpeechFeeder

/// Feeds a `SpeechSynthesizer` from a growing streamed reply, sentence by
/// sentence, without waiting for the whole response. Whole fenced code
/// blocks are skipped and replaced with a single spoken placeholder instead
/// of being read character-by-character.
@MainActor
final class StreamingSpeechFeeder {
    private let synth: SpeechSynthesizer
    private var spokenOffset = 0
    private var insideCodeBlock = false
    private var announcedCurrentBlock = false

    init(synth: SpeechSynthesizer) {
        self.synth = synth
    }

    /// Call once when a new assistant reply starts streaming.
    func reset() {
        spokenOffset = 0
        insideCodeBlock = false
        announcedCurrentBlock = false
    }

    /// `fullContent` is the *entire* accumulated reply so far (not just the
    /// latest delta) — sentence/fence boundaries can straddle two deltas, so
    /// re-scanning from the last consumed offset is simpler than stitching
    /// partial markers across calls. `isFinal` flushes a trailing partial
    /// sentence once streaming ends.
    func consume(fullContent: String, isFinal: Bool = false) {
        let chars = Array(fullContent)

        while spokenOffset < chars.count {
            if insideCodeBlock {
                if !announcedCurrentBlock {
                    synth.speak("...blok kodu...")
                    announcedCurrentBlock = true
                }
                guard let closeIdx = Self.fenceIndex(chars, from: spokenOffset) else { return }
                spokenOffset = closeIdx + 3
                insideCodeBlock = false
                announcedCurrentBlock = false
                continue
            }

            if let fenceIdx = Self.fenceIndex(chars, from: spokenOffset) {
                if let cutIdx = Self.sentenceCut(chars, from: spokenOffset, limit: fenceIdx) {
                    speak(chars, spokenOffset..<(cutIdx + 1))
                    spokenOffset = cutIdx + 1
                    continue
                }
                if fenceIdx > spokenOffset {
                    speak(chars, spokenOffset..<fenceIdx)
                }
                spokenOffset = fenceIdx + 3
                insideCodeBlock = true
                continue
            }

            if let cutIdx = Self.sentenceCut(chars, from: spokenOffset, limit: chars.count) {
                speak(chars, spokenOffset..<(cutIdx + 1))
                spokenOffset = cutIdx + 1
                continue
            }

            if isFinal {
                speak(chars, spokenOffset..<chars.count)
                spokenOffset = chars.count
            }
            return
        }
    }

    private func speak(_ chars: [Character], _ range: Range<Int>) {
        guard range.lowerBound < range.upperBound else { return }
        let cleaned = Self.stripMarkdown(String(chars[range]))
        guard !cleaned.isEmpty else { return }
        synth.speak(cleaned)
    }

    /// First `` ``` `` fence at or after `start`, if any.
    private static func fenceIndex(_ chars: [Character], from start: Int) -> Int? {
        guard chars.count >= 3 else { return nil }
        var i = start
        while i <= chars.count - 3 {
            if chars[i] == "`", chars[i + 1] == "`", chars[i + 2] == "`" { return i }
            i += 1
        }
        return nil
    }

    /// Index of a sentence-ending punctuation mark at least 10 characters
    /// after `start` (short fragments get merged into the next sentence
    /// instead of triggering a one-word utterance).
    private static func sentenceCut(_ chars: [Character], from start: Int, limit: Int) -> Int? {
        var searchStart = start
        while searchStart < limit {
            guard let idx = terminatorIndex(chars, from: searchStart, limit: limit) else { return nil }
            if idx - start + 1 >= 10 { return idx }
            searchStart = idx + 1
        }
        return nil
    }

    private static func terminatorIndex(_ chars: [Character], from start: Int, limit: Int) -> Int? {
        var i = start
        while i < limit {
            let c = chars[i]
            if c == "." || c == "!" || c == "?" || c == "\n" { return i }
            i += 1
        }
        return nil
    }

    /// Strips the markdown syntax that would otherwise be read aloud
    /// literally ("gwiazdka gwiazdka pogrubione..."). Fenced code is handled
    /// separately by the caller — this only cleans plain-text sentences.
    static func stripMarkdown(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        result = result.replacingOccurrences(of: "`", with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
