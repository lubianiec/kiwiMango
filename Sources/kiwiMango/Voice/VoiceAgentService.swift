import Foundation
import Speech
import AVFoundation

// MARK: - VoiceAgentService (PLAN-VOICE-V4 — natywny SFSpeechRecognizer)
//
// v3 łączył się do Grok STT (`wss://api.x.ai/v1/stt`) — beta API, na żywo
// wyszły dwa bugi (duplikaty tekstu, fonetyczne pomyłki na czeską pisownię)
// i wymagało płatnego klucza. Paweł: "słabo te xai działa, nie ma czegoś
// lepszego?". Jest: Apple's Speech framework — ten sam silnik co systemowe
// Dictation, lata w produkcji, offline-first, ZERO kluczy/kosztów/sieci.
@Observable
final class VoiceAgentService: NSObject {

    enum State: Equatable {
        case idle
        case listening
        case error(String)
    }

    private(set) var state: State = .idle

    /// Głośność mikrofonu na żywo, 0...1 — napędza wizualizację fali w composerze.
    private(set) var audioLevel: Float = 0

    /// Wołane z GROWING/cumulative tekstem całej bieżącej wypowiedzi (SFSpeechRecognizer
    /// zwraca zawsze CAŁY dotychczasowy tekst, nie delty) — `ConversationView`
    /// doklei to do tekstu sprzed dyktowania, NIE append-uje kawałek po kawałku.
    var onTranscript: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pl-PL"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    override init() { super.init() }

    // MARK: - Public

    func toggle() {
        switch state {
        case .idle, .error:
            start()
        case .listening:
            stop()
        }
    }

    func start() {
        guard state == .idle || isError else { return }
        guard let recognizer, recognizer.isAvailable else {
            setState(.error("Rozpoznawanie mowy niedostępne — sprawdź System Settings → Klawiatura → Dyktowanie."))
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                guard authStatus == .authorized else {
                    self?.setState(.error("Brak zgody — System Settings → Prywatność i bezpieczeństwo → Rozpoznawanie mowy."))
                    return
                }
                self?.beginRecognition()
            }
        }
    }

    private func beginRecognition() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            self?.updateAudioLevel(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            request = nil
            setState(.error("Mikrofon: \(error.localizedDescription)"))
            return
        }

        setState(.listening)
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.onTranscript?(result.bestTranscription.formattedString)
            }
            if let error {
                // Klik "stop" sam w sobie kończy request z błędem anulowania —
                // to NIE jest prawdziwy błąd, tylko efekt uboczny `endAudio()`.
                let ns = error as NSError
                if ns.domain == "kAFAssistantErrorDomain" && ns.code == 216 { return }
                self.fail("Rozpoznawanie: \(error.localizedDescription)")
            }
        }
    }

    /// Klik na mikrofon podczas nasłuchu = kończymy tę wypowiedź i zwalniamy mic
    /// natychmiast (nie czekamy na `isFinal` z recognizera — bywa opóźnione).
    func stop() {
        teardown()
        if case .error = state { return } // zostaw komunikat błędu widoczny
        setState(.idle)
    }

    // MARK: - Cleanup

    private func teardown() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        setAudioLevel(0)
    }

    /// Błąd w trakcie nasłuchu MUSI zwolnić mikrofon przed pokazaniem komunikatu
    /// (lekcja z v3 — inaczej appka "nie da się wyłączyć w żaden sposób").
    private func fail(_ message: String) {
        teardown()
        setState(.error(message))
    }

    // MARK: - Audio level (dla fali w UI)

    private func updateAudioLevel(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        var sumSquares: Float = 0
        let samples = channelData[0]
        for i in 0..<frameCount { sumSquares += samples[i] * samples[i] }
        let rms = (sumSquares / Float(frameCount)).squareRoot()
        setAudioLevel(min(1, rms.squareRoot() * 2.2))
    }

    // MARK: - State helpers

    private var isError: Bool {
        if case .error = state { return true }
        return false
    }

    /// Callbacki ze Speech framework przychodzą poza main threadem.
    private func setState(_ newState: State) {
        DispatchQueue.main.async { self.state = newState }
    }

    private func setAudioLevel(_ level: Float) {
        DispatchQueue.main.async { self.audioLevel = level }
    }
}
