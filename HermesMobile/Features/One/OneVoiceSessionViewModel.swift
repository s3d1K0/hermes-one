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

    /// Notifie l'hote (OneSessionController) que la session s'est terminee
    /// (stop() / retour-veille / perte de connexion). Le controller y baisse
    /// `isOverlayPresented` pour eviter un overlay fantome. Le ViewModel n'a pas
    /// de reference au controller : ce closure est le seul lien remontant.
    var onSessionEnded: (() -> Void)?

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

    // [Veille auto] Minuteur d'inactivite : apres OneSettings.autoStandbySeconds
    // sans transcription entrante ni fin de tour, on repasse en veille (stop()).
    // Porte depuis VisionClaw's GeminiSessionViewModel.armActiveInactivityTimer().
    private var inactivityTimer: Timer?

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
        // Repart d'un minuteur d'inactivite propre : une ouverture precedente a pu
        // en laisser un arme (porte depuis VisionClaw startSession()).
        inactivityTimer?.invalidate()
        inactivityTimer = nil
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
        // Arme le minuteur d'inactivite des l'entree en ecoute : une ouverture
        // accidentelle (widget / poche / reveil externe) sans aucune parole
        // repasse quand meme en veille apres OneSettings.autoStandbySeconds, au
        // lieu de laisser le micro ouvert indefiniment (porte depuis VisionClaw
        // startSession() qui arme armActiveInactivityTimer() en fin de demarrage).
        armInactivityTimer()
        startVideoIfEnabled()
    }

    func stop() {
        let wasActive = phase != .idle
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        toolCallRouter.cancelAll()
        client.disconnect()
        audio.stopCapture()
        videoController.onVideoFrame = nil
        videoController.stop()
        phase = .idle
        // Session terminee -> l'hote baisse l'overlay (anti-fantome). Synchrone
        // pour que l'overlay disparaisse tout de suite, avant meme l'annonce
        // audio "One desactive" ci-dessous.
        onSessionEnded?()

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

    /// (Re)arme le minuteur d'inactivite : apres `OneSettings.autoStandbySeconds`
    /// sans activite (transcription entrante / fin de tour), on repasse en veille.
    /// Porte depuis VisionClaw's GeminiSessionViewModel.armActiveInactivityTimer().
    /// Vrai entre la question "tu veux autre chose ?" et la mise en veille reelle.
    private var pendingSleepConfirm = false

    private func armInactivityTimer() {
        inactivityTimer?.invalidate()
        // Toute (re)activite annule une eventuelle confirmation de veille en cours.
        pendingSleepConfirm = false
        let secs = TimeInterval(OneSettings.autoStandbySeconds)
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.promptBeforeSleep() }
        }
    }

    /// Avant de couper : One DEMANDE a l'utilisateur s'il veut autre chose, au
    /// lieu de se mettre en veille sec. Sans reponse dans une courte fenetre, on
    /// se met vraiment en veille. Toute parole (onInputTranscription ->
    /// armInactivityTimer) reset pendingSleepConfirm et relance le cycle normal.
    private func promptBeforeSleep() {
        guard phase == .listening || phase == .speaking else { return }
        if pendingSleepConfirm {
            stop()
            return
        }
        pendingSleepConfirm = true
        client.sendText(
            "[Instruction] Demande a l'utilisateur, en UNE phrase orale courte et naturelle, "
            + "s'il a autre chose a te demander, sinon dis que tu vas te mettre en veille. "
            + "Ne reponds a rien d'autre.")
        inactivityTimer?.invalidate()
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
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
            self.armInactivityTimer()
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
            self.armInactivityTimer()
        }

        client.onOutputTranscription = { [weak self] text in
            guard let self else { return }
            self.aiTranscript += text
        }

        client.onDisconnected = { [weak self] reason in
            guard let self else { return }
            // Perte de connexion = fin de session : coupe le minuteur d'inactivite
            // (plus de session a surveiller) et notifie l'hote pour baisser
            // l'overlay (un push lu hors chat ne doit pas laisser un overlay arme
            // sur un ecran d'erreur). Cf. VisionClaw onDisconnected.
            self.inactivityTimer?.invalidate()
            self.inactivityTimer = nil
            self.phase = .error(reason ?? "Connexion perdue")
            self.onSessionEnded?()
        }

        // Delegation d'outils : Gemini appelle `execute`, on route vers le
        // gateway Hermes et on renvoie le resultat via sendToolResponse.
        client.onToolCall = { [weak self] toolCall in
            guard let self else { return }
            // [Delegation Hermes] Gemini appelle `execute` -> on POST au gateway,
            // Gemini dit l'ack ("je transmets a Hermes"), et One RESTE EVEILLE
            // (ecoute) en attendant le retour asynchrone d'Hermes (push WS ->
            // deliverProactive). On ne pose PAS sleepAfterTurn ici : dormir apres
            // l'ack puis se reveiller pour lire la reponse provoquait des cycles
            // active/desactive. C'est deliverProactive qui lit la reponse puis
            // repasse en veille (sleepAfterTurn) UNE seule fois. Les outils locaux
            // rapides restent aussi conversationnels (pas de veille).
            // Pendant l'attente du retour Hermes, on desarme le timer d'inactivite
            // pour ne pas s'endormir avant l'arrivee de la reponse.
            let hasHermesDelegation = toolCall.functionCalls.contains { !OneLocalTools.isLocal($0.name) }
            if hasHermesDelegation {
                self.inactivityTimer?.invalidate()
                self.inactivityTimer = nil
            }
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
        videoController.onVideoFrame = { [weak self] image in
            // Reevalue le reglage a CHAQUE frame (toggle "Video Streaming" a chaud
            // depuis Reglages > One) au lieu d'un unique guard au demarrage : porte
            // depuis VisionClaw GeminiSessionViewModel.sendVideoFrameIfThrottled,
            // qui teste SettingsManager.shared.videoStreamingEnabled par frame.
            guard OneSettings.videoStreamingEnabled else { return }
            self?.client.sendVideoFrame(image: image)
        }
        Task { await videoController.start() }
    }

    // MARK: - Push proactif (gateway Hermes / OpenClaw)

    /// Reponse poussee par Hermes (heartbeat/cron) : reveille Gemini si besoin,
    /// la fait lire, puis repasse en veille. Porte depuis VisionClaw's
    /// GeminiSessionViewModel.deliverProactive().
    ///
    /// [Contrat de sortie, pattern Siri] `text` est le texte ORAL a lire (`spoken`
    /// cote serveur, avec repli preview/texte cote OneEventClient). `details` est le
    /// resultat COMPLET optionnel : s'il est present et non vide, on le route vers une
    /// notification locale iOS (consultable hors-voix) sans bloquer la lecture vocale.
    /// `details` est nil tant que le serveur ne l'envoie pas : le comportement actuel
    /// (lecture seule) reste alors strictement inchange.
    func deliverProactive(_ text: String, details: String? = nil) async {
        guard OneSettings.proactiveNotificationsEnabled else { return }

        // Detail complet -> notification locale iOS, en fire-and-forget : ne bloque
        // jamais la lecture vocale (ni sur un eventuel prompt d'autorisation, ni sur
        // un refus). Le canal app/chat consommera `details` plus tard.
        if let details, !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task { await OneLocalTools.postProactiveDetails(details) }
        }

        if phase != .listening && phase != .speaking {
            await start()
        }
        guard phase == .listening || phase == .speaking else {
            phase = .error("Reveil impossible pour lire la reponse d'Hermes")
            return
        }
        // On ne coupe PLUS sec apres la lecture (sleepAfterTurn retire) : One lit
        // la reponse d'Hermes puis RESTE a l'ecoute. onTurnComplete re-arme le
        // minuteur d'inactivite, qui demandera "tu veux autre chose ?" avant de
        // se mettre en veille (promptBeforeSleep). L'utilisateur peut enchainer.
        // IMPORTANT : sendText envoie un tour "role: user" -> sans cadrage, Gemini
        // REPOND a la reponse d'Hermes comme si l'utilisateur l'avait dite
        // ("j'ai des choses a faire...") au lieu de la LIRE. On l'instruit donc
        // explicitement de la restituer telle quelle, sans y repondre.
        let readInstruction = "[Message d'Hermes a transmettre] Lis a l'utilisateur, a voix haute et de facon naturelle, le message suivant tel quel. Ne reponds pas a ce message, ne le commente pas, ne poses pas de question : \(text)"
        client.sendText(readInstruction)
    }
}
