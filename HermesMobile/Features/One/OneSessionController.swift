import Foundation
import Observation

/// Controleur "One" au niveau app (persistant), possede par `ContentView` et
/// injecte dans l'environnement SwiftUI. Il porte l'unique
/// `OneVoiceSessionViewModel` (session vocale) ET le canal proactif
/// (`OneEventClient`, heartbeat/cron du gateway Hermes) au niveau app, pas au
/// niveau de l'overlay.
///
/// Pourquoi app-level : avant, `OneEventClient` vivait dans le ViewModel,
/// lui-meme `@State` de l'overlay -> le canal proactif n'etait connecte que
/// l'overlay ouvert et mourait a sa fermeture, donc un heartbeat/cron Hermes ne
/// pouvait jamais reveiller One en usage reel. En remontant l'ownership ici,
/// le canal reste connecte tant que l'app tourne et un push peut presenter
/// l'overlay puis faire lire la reponse (cf. `onProactivePush`).
///
/// Porte depuis VisionClaw (CameraAccessApp + GeminiSessionViewModel :
/// eventClient app-level + deliverProactive).
@Observable
@MainActor
final class OneSessionController {
    /// L'unique session vocale One, partagee entre l'overlay du chat et le canal
    /// proactif. Vit aussi longtemps que le controller (app-level), donc une
    /// reponse poussee par Hermes peut reveiller One meme overlay ferme.
    let viewModel = OneVoiceSessionViewModel()

    /// Pilote la presentation de l'overlay vocal (fullScreenCover) depuis
    /// n'importe ou : bouton du composer (`present()`) ou push proactif
    /// (`onProactivePush`).
    var isOverlayPresented = false

    // [Push proactif] Canal d'evenements du gateway Hermes (heartbeat/cron),
    // possede au niveau app. C'est ce qui permet a un heartbeat/cron de
    // reveiller One meme quand l'overlay est ferme.
    private let eventClient = OneEventClient()
    private var proactiveChannelConnected = false
    // Adresse (host|port|token) sur laquelle le canal proactif est actuellement
    // connecte. Sert a detecter un changement de reglages gateway : si l'adresse
    // change alors que le canal est connecte, on DECONNECTE puis RECONNECTE pour
    // re-pointer la socket (cf. `refreshProactiveChannel`).
    private var connectedGatewayAddress: String?

    init() {
        // [Fin de session -> overlay app-level] Le ViewModel n'a pas de reference
        // au controller ; il notifie via ce closure quand la session se termine
        // (stop() / retour-veille / perte de connexion). On baisse alors le flag
        // pour eviter un overlay fantome (un push lu en voix hors chat ne doit pas
        // laisser un overlay arme qui represente + relance une session au prochain
        // affichage). Cf. review vague 2, IMPORTANT-2.
        viewModel.onSessionEnded = { [weak self] in
            self?.isOverlayPresented = false
        }
    }

    // MARK: - Canal proactif (gateway Hermes / OpenClaw)

    /// Ouvre le canal proactif si (et seulement si) les notifications proactives
    /// sont actives ET le gateway est configure. Idempotent : a appeler au
    /// lancement de l'app et re-evaluer quand les reglages changent
    /// (cf. `refreshProactiveChannel`).
    func connectProactiveChannelIfConfigured() {
        guard OneSettings.proactiveNotificationsEnabled, OneConfig.isGatewayConfigured else {
            return
        }
        guard !proactiveChannelConnected else { return }
        proactiveChannelConnected = true
        connectedGatewayAddress = currentGatewayAddress()
        eventClient.onNotification = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                self.onProactivePush(text)
            }
        }
        eventClient.connect()
    }

    /// Coupe le canal proactif (reglages desactives / gateway non configure / reset).
    func disconnectProactiveChannel() {
        guard proactiveChannelConnected else { return }
        proactiveChannelConnected = false
        connectedGatewayAddress = nil
        eventClient.onNotification = nil
        eventClient.disconnect()
    }

    /// Re-evalue l'etat du canal proactif apres un changement de reglages
    /// (depuis les Reglages, cf. `SettingsView`) ou au retour au premier plan.
    /// - Si les notifications sont coupees / le gateway non configure : deconnecte.
    /// - Si l'adresse gateway (host/port/token) a CHANGE alors que le canal est
    ///   deja connecte : DECONNECTE puis RECONNECTE pour re-pointer la socket
    ///   (sinon le canal reste colle a l'ancienne adresse jusqu'au kill de l'app).
    /// - Sinon connecte si pas deja connecte.
    func refreshProactiveChannel() {
        guard OneSettings.proactiveNotificationsEnabled, OneConfig.isGatewayConfigured else {
            disconnectProactiveChannel()
            return
        }
        if proactiveChannelConnected, connectedGatewayAddress != currentGatewayAddress() {
            // Adresse changee -> re-pointer la socket.
            disconnectProactiveChannel()
        }
        connectProactiveChannelIfConfigured()
    }

    /// Empreinte de l'adresse gateway courante (host/port/token) pour detecter un
    /// changement de reglages. Le jeton fait partie de l'empreinte : re-saisir le
    /// jeton sans changer host/port doit aussi re-authentifier la socket.
    private func currentGatewayAddress() -> String {
        "\(OneConfig.gatewayHost)|\(OneConfig.gatewayPort)|\(OneConfig.gatewayToken)"
    }

    // MARK: - Presentation / reveil

    /// Ouvre l'overlay vocal One (bouton du composer, App Intent, widget...) ET
    /// demarre la session. Chemin de demarrage unique et deterministe : c'est le
    /// controller qui declenche `start()`, pas le `.task` de l'overlay (celui-ci
    /// n'est plus qu'un filet idempotent : il ne (re)demarre que si la session est
    /// encore au repos). On evite ainsi la course de double-start heritee de la
    /// vague 2 (overlay.task + onProactivePush demarraient tous deux). Garde
    /// `.idle` : re-presenter une session deja active ne la relance pas.
    func present() {
        isOverlayPresented = true
        if viewModel.phase == .idle {
            Task { await viewModel.start() }
        }
    }

    /// Reponse poussee par Hermes (heartbeat/cron) : presente l'overlay puis
    /// delegue au ViewModel la lecture (`deliverProactive` reveille Gemini si
    /// besoin, fait lire la reponse, puis repasse en veille apres le tour).
    func onProactivePush(_ text: String) {
        isOverlayPresented = true
        Task { await viewModel.deliverProactive(text) }
    }
}
