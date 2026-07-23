import AVFoundation
import Foundation
import Observation

/// Orchestre une session vocale "One" : capture micro -> Gemini Live -> lecture
/// audio, avec transcriptions live. Version simplifiee (pas de widget, pas de
/// veille, pas de video) portee depuis VisionClaw's GeminiSessionViewModel.
@Observable
@MainActor
final class OneVoiceSessionViewModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case listening
        case speaking
        case error(String)
    }

    var phase: Phase = .idle
    var userTranscript: String = ""
    var aiTranscript: String = ""

    private let client = OneGeminiLiveClient()
    private let audio = OneAudioController()

    func start() async {
        guard phase != .connecting else { return }
        phase = .connecting
        userTranscript = ""
        aiTranscript = ""

        guard OneConfig.isConfigured else {
            phase = .error("Cle API Gemini non configuree (OneSecrets.swift)")
            return
        }

        wireCallbacks()

        do {
            try audio.setupSession()
        } catch {
            phase = .error("Audio setup failed: \(error.localizedDescription)")
            return
        }

        let connected = await client.connect()
        guard connected else {
            let msg: String
            if case .error(let err) = client.connectionState {
                msg = err
            } else {
                msg = "Failed to connect to Gemini"
            }
            phase = .error(msg)
            return
        }

        do {
            try audio.startCapture()
        } catch {
            phase = .error("Mic capture failed: \(error.localizedDescription)")
            client.disconnect()
            return
        }

        phase = .listening
    }

    func stop() {
        client.disconnect()
        audio.stopCapture()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        phase = .idle
    }

    // MARK: - Private

    private func wireCallbacks() {
        audio.onAudioCaptured = { [weak self] data in
            self?.client.sendAudio(data)
        }

        client.onAudioReceived = { [weak self] data in
            guard let self else { return }
            self.phase = .speaking
            self.audio.playAudio(data)
        }

        client.onInterrupted = { [weak self] in
            guard let self else { return }
            self.audio.stopPlayback()
            self.phase = .listening
        }

        client.onTurnComplete = { [weak self] in
            guard let self else { return }
            self.phase = .listening
            self.userTranscript = ""
        }

        client.onInputTranscription = { [weak self] text in
            guard let self else { return }
            self.userTranscript += text
            self.aiTranscript = ""
        }

        client.onOutputTranscription = { [weak self] text in
            guard let self else { return }
            self.aiTranscript += text
        }

        client.onDisconnected = { [weak self] reason in
            guard let self else { return }
            self.phase = .error(reason ?? "Connexion perdue")
        }
    }
}
