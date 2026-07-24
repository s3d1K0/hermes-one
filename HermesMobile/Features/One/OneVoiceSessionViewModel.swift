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
    private let voiceFeedback = OneVoiceFeedback()
    // Video lunettes (Meta Wearables DAT SDK) -> Gemini, portee depuis VisionClaw's
    // StreamSessionViewModel ; active seulement si OneSettings.videoStreamingEnabled.
    // Instance partagee (Task 5) : la meme que celle pilotee par la vue Reglages,
    // pour que l'appairage fait dans les Reglages rende la video atteignable ici.
    private let wearablesController = OneWearablesController.shared
    private let videoController: OneVideoController
    // [Push proactif] Le canal d'evenements du gateway Hermes (OneEventClient) ne
    // vit PLUS ici : il est possede par OneSessionController au niveau app, pour
    // rester connecte meme overlay ferme. Ce ViewModel n'expose que
    // `deliverProactive(_:)`, pilote par le controller a la reception d'un push.
    // Repasser en veille (stop()) au prochain tour Gemini termine, pour une
    // lecture de push proactif (evite de laisser le micro ouvert derriere).
    private var sleepAfterTurn = false

    // Delegation d'outils (Gemini execute -> gateway Hermes), portee depuis
    // VisionClaw's ContentView (OpenClawBridge + ToolCallRouter).
    private let hermesBridge = OneHermesBridge()
    private let toolCallRouter: OneToolCallRouter

    init() {
        toolCallRouter = OneToolCallRouter(bridge: hermesBridge)
        videoController = OneVideoController(wearables: wearablesController.wearables)
    }

    func start() async {
        guard phase != .connecting else { return }
        phase = .connecting
        userTranscript = ""
        aiTranscript = ""

        guard OneConfig.isConfigured else {
            phase = .error("Cle API Gemini non configuree (Reglages > One)")
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

        // Annonce "One active" (lunettes) avant d'ouvrir le micro : confirme a
        // l'utilisateur que One tient la parole et evite que le micro capture
        // sa propre synthese pendant qu'elle joue.
        await announce("One active")

        do {
            try audio.startCapture()
        } catch {
            phase = .error("Mic capture failed: \(error.localizedDescription)")
            client.disconnect()
            return
        }

        phase = .listening
        startVideoIfEnabled()
    }

    func stop() {
        let wasActive = phase != .idle
        toolCallRouter.cancelAll()
        client.disconnect()
        audio.stopCapture()
        videoController.onVideoFrame = nil
        videoController.stop()
        phase = .idle

        guard wasActive else {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            return
        }

        // Annonce "One desactive" puis libere la session audio seulement une
        // fois la phrase terminee (evite de couper le HFP en pleine syntese).
        voiceFeedback.say("One desactive") {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    // MARK: - Private

    /// Prononce `text` et attend la fin de la synthese (avec filet de securite
    /// si le delegate AVSpeechSynthesizer ne notifie jamais), portee depuis le
    /// pattern completion+fallback de VisionClaw's activateOne().
    private func announce(_ text: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var didResume = false
            let resumeOnce = {
                guard !didResume else { return }
                didResume = true
                continuation.resume()
            }
            voiceFeedback.say(text) { resumeOnce() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { resumeOnce() }
        }
    }

    private func wireCallbacks() {
        audio.onAudioCaptured = { [weak self] data in
            guard let self else { return }
            // [Anti-echo half-duplex] En mode Speaker Output, le micro reinjecte
            // la voix de Gemini -> boucle d'echo. On coupe l'envoi tant que le
            // modele parle (portee de VisionClaw GeminiSessionViewModel.startSession).
            if OneSettings.speakerOutputEnabled && self.client.isModelSpeaking { return }
            self.client.sendAudio(data)
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
            self.userTranscript = ""
            // [Push proactif] Apres la lecture d'un push Hermes, on repasse en
            // veille au lieu de laisser le micro ouvert.
            if self.sleepAfterTurn {
                self.sleepAfterTurn = false
                self.stop()
            } else {
                self.phase = .listening
            }
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

        // Delegation d'outils : Gemini appelle `execute`, on route vers le
        // gateway Hermes et on renvoie le resultat via sendToolResponse.
        client.onToolCall = { [weak self] toolCall in
            guard let self else { return }
            for call in toolCall.functionCalls {
                self.toolCallRouter.handleToolCall(call) { [weak self] response in
                    self?.client.sendToolResponse(response)
                }
            }
        }

        client.onToolCallCancellation = { [weak self] cancellation in
            self?.toolCallRouter.cancelToolCalls(ids: cancellation.ids)
        }
    }

    // MARK: - Video lunettes (Meta Wearables DAT SDK)

    /// Demarre le flux video lunettes -> Gemini si le reglage "video" (Reglages > One)
    /// est actif. Tolerant : si aucune lunette n'est appairee (ou en simulateur sans
    /// mock device), OneVideoController reporte l'echec dans son propre etat sans
    /// jamais interrompre la session vocale (audio only).
    private func startVideoIfEnabled() {
        guard OneSettings.videoStreamingEnabled else { return }
        videoController.onVideoFrame = { [weak self] image in
            self?.client.sendVideoFrame(image: image)
        }
        Task { await videoController.start() }
    }

    // MARK: - Push proactif (gateway Hermes / OpenClaw)

    /// Reponse poussee par Hermes (heartbeat/cron) : reveille Gemini si besoin,
    /// la fait lire, puis repasse en veille. Porte depuis VisionClaw's
    /// GeminiSessionViewModel.deliverProactive().
    func deliverProactive(_ text: String) async {
        guard OneSettings.proactiveNotificationsEnabled else { return }

        if phase != .listening && phase != .speaking {
            await start()
        }
        guard phase == .listening || phase == .speaking else {
            phase = .error("Reveil impossible pour lire la reponse d'Hermes")
            return
        }
        sleepAfterTurn = true
        client.sendText(text)
    }
}
