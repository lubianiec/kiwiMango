import AVFoundation
import Foundation
import Observation
import Speech

// MARK: - SpeechRecognizer

/// Polish speech-to-text for the composer's dictation button. Wraps
/// `SFSpeechRecognizer` + `AVAudioEngine`: `start()` begins listening and
/// streaming partial results into `transcript`; `stop()` ends the session.
@MainActor
@Observable
final class SpeechRecognizer {

    private(set) var transcript = ""
    private(set) var isRecording = false
    private(set) var authorizationDenied = false

    /// Fired on every partial result — used by `VoiceLoopController` to reset
    /// its silence timer without touching the composer dictation behavior.
    @ObservationIgnored var onPartialResult: (() -> Void)?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pl_PL"))
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    func start() async {
        guard !isRecording else { return }
        transcript = ""

        guard await requestAuthorization() else {
            authorizationDenied = true
            return
        }
        authorizationDenied = false

        guard let recognizer, recognizer.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [request] buffer, _ in
            request.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("[KiwiMango] Failed to start audio engine: \(error)")
            return
        }

        isRecording = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.onPartialResult?()
                }
                if error != nil || result?.isFinal == true {
                    self.stopEngine()
                }
            }
        }
    }

    func stop() {
        request?.endAudio()
        stopEngine()
    }

    private func stopEngine() {
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request = nil
        task?.cancel()
        task = nil
        isRecording = false
    }

    /// Requests both speech-recognition and microphone authorization. Returns
    /// `true` only if both are granted.
    private func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }

        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
