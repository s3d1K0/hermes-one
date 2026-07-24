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

    init() {}

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
        eventClient.onNotification = nil
        eventClient.disconnect()
    }

    /// Re-evalue l'etat du canal proactif apres un changement de reglages ou au
    /// retour au premier plan : le connecte ou le coupe selon les reglages actuels.
    func refreshProactiveChannel() {
        if OneSettings.proactiveNotificationsEnabled, OneConfig.isGatewayConfigured {
            connectProactiveChannelIfConfigured()
        } else {
            disconnectProactiveChannel()
        }
    }

    // MARK: - Presentation / reveil

    /// Ouvre l'overlay vocal One (bouton du composer, App Intent, widget...).
    func present() {
        isOverlayPresented = true
    }

    /// Reponse poussee par Hermes (heartbeat/cron) : presente l'overlay puis
    /// delegue au ViewModel la lecture (`deliverProactive` reveille Gemini si
    /// besoin, fait lire la reponse, puis repasse en veille apres le tour).
    func onProactivePush(_ text: String) {
        isOverlayPresented = true
        Task { await viewModel.deliverProactive(text) }
    }
}
