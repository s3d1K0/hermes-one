import SwiftUI

struct ContentView: View {
    @Bindable var authManager: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ResponseCompletionNotifications.isEnabledKey) private var isResponseCompletionNotificationsEnabled = false
    @State private var pendingSharedImport: SharedImport?
    @State private var pendingDeepLinkedSessionID: String?
    @State private var pendingNewChatRequest: NewChatRequest?
    @State private var didCheckInitialPendingShare = false
    @State private var intentRouter = AppIntentRouter.shared
    // Controleur One app-level : possede le canal proactif (heartbeat/cron du
    // gateway Hermes) + l'unique session vocale, connecte au lancement et
    // re-evalue a chaque retour au premier plan. Injecte dans l'environnement
    // pour que ChatView (overlay) et le reveil externe partagent le meme objet.
    @State private var oneController = OneSessionController()
    // [One] Anti-rebond du reveil externe : `scenePhase == .active` peut se
    // declencher en rafale (ex. bascule rapide app-switcher). `consume()` purge
    // deja le flag (donc un reveil unique), mais on ignore aussi tout reveil dans
    // la seconde qui suit le precedent, par securite (garde 1.0s, fidelite
    // VisionClaw `toggleOne`).
    @State private var lastOneWakeAt: Date?

    var body: some View {
        content
            .environment(oneController)
            // Overlay vocal One remonte au niveau HOTE APP (et non plus dans
            // ChatView) : il peut ainsi apparaitre depuis N'IMPORTE QUEL ecran
            // (liste des sessions, onboarding, reveil externe cold-start), pas
            // seulement quand un chat est a l'ecran. Presentation pilotee par le
            // controller (present() / onProactivePush) ; fin de session baisse le
            // flag (anti-fantome). Cf. review vague 2, IMPORTANT-1/-2.
            .fullScreenCover(isPresented: oneOverlayPresentedBinding) {
                OneVoiceOverlayView(
                    vm: oneController.viewModel,
                    onClose: { oneController.isOverlayPresented = false }
                )
            }
            .onOpenURL(perform: handleOpenURL)
            .task {
                // Ouvre le canal proactif au lancement s'il est configure, pour
                // qu'un push Hermes puisse reveiller One meme overlay ferme.
                oneController.connectProactiveChannelIfConfigured()
            }
            .task {
                guard !didCheckInitialPendingShare else { return }
                didCheckInitialPendingShare = true
                importPendingSharedDraftIfAvailable()
                // Cold launch: an App Intent may have queued a deep link before this
                // view appeared (e.g. Action button "New Chat"). Drain it now (#337).
                drainPendingIntentDeepLink()
            }
            .onChange(of: intentRouter.pendingDeepLink) {
                // Warm launch: the intent set the deep link after the view appeared.
                drainPendingIntentDeepLink()
            }
            .task {
                // #246: on cold launch, end any Live Activity left "running" by a
                // run that finished while the app was terminated. #248: this is also
                // the one pass allowed to fire a recent run's "response complete"
                // notification, since a relaunch means it finished while not active.
                await reconcileOrphanedLiveActivities(notifiesOnCompletion: true)
            }
            .onChange(of: scenePhase) {
                guard scenePhase == .active else { return }
                // Re-evalue le canal proactif : les reglages One (host/port/token,
                // toggle notifications) ont pu changer pendant que l'app etait en fond.
                oneController.refreshProactiveChannel()
                // Reveil externe (widget / Centre de controle / Raccourcis) : l'App
                // Intent a pose un flag dans l'App Group. On le consomme au premier
                // plan et on presente l'overlay vocal One, avec anti-rebond 1s.
                consumeOneWakeSignalIfNeeded()
                importPendingSharedDraftIfAvailable()
                // #248: the foreground pass stays silent — the in-session completion
                // paths own notifications while the app is alive.
                Task { await reconcileOrphanedLiveActivities(notifiesOnCompletion: false) }
            }
    }

    /// Consomme le flag de reveil externe pose par `OneActivationIntent` (widget /
    /// Centre de controle) et presente l'overlay vocal One. Anti-rebond 1s pour
    /// absorber un `scenePhase == .active` qui se declenche en rafale (fidelite
    /// VisionClaw `toggleOne`).
    private func consumeOneWakeSignalIfNeeded() {
        guard OneWakeSignal.consume() else { return }
        let now = Date()
        if let last = lastOneWakeAt, now.timeIntervalSince(last) <= 1.0 { return }
        lastOneWakeAt = now
        oneController.present()
    }

    /// Binding vers l'etat de presentation de l'overlay One, possede par le
    /// controller app-level. Extrait de `body` pour tenir la chaine de modifieurs
    /// sous la limite de type-check du compilateur.
    private var oneOverlayPresentedBinding: Binding<Bool> {
        Binding(
            get: { oneController.isOverlayPresented },
            set: { oneController.isOverlayPresented = $0 }
        )
    }

    private func reconcileOrphanedLiveActivities(notifiesOnCompletion: Bool) async {
        guard case let .loggedIn(server) = authManager.state else { return }
        await LiveActivityReconciler.reconcileOrphanedActivities(
            server: server,
            notifiesOnCompletion: notifiesOnCompletion,
            preferenceEnabled: isResponseCompletionNotificationsEnabled
        )
    }

    @ViewBuilder
    private var content: some View {
        switch authManager.state {
        case .unconfigured:
            OnboardingView(authManager: authManager)
        case .loggedOut(let server):
            OnboardingView(authManager: authManager, savedServer: server)
        case .loggedIn(let server):
            SessionListView(
                authManager: authManager,
                server: server,
                pendingSharedImport: $pendingSharedImport,
                pendingDeepLinkedSessionID: $pendingDeepLinkedSessionID,
                requestedNewChat: $pendingNewChatRequest
            )
            // Switching the active server keeps us in `.loggedIn`, so without a
            // per-server identity SwiftUI would reuse the same SessionListView (and
            // its server-bound view model), leaving stale sessions/chat on screen.
            // Keying on the server tears the whole stack down and rebuilds it
            // against the newly active server (#17).
            .id(server)
        }
    }

    private func handleOpenURL(_ url: URL) {
        // A fresh request each time (new `id`) so a repeat invocation re-triggers navigation
        // even if the previous one's value still lingers downstream. The voice variant carries
        // `autoStartsVoiceInput` so the composer begins dictation once it appears (#338).
        if HermesDeepLink.isNewChatVoiceURL(url) {
            pendingNewChatRequest = NewChatRequest(autoStartsVoiceInput: true)
            return
        }

        // The profile variant carries the chosen profile name, so the composer creates the
        // session pinned to it (#339). A malformed link with no profile falls back to a
        // plain new chat (server's active profile) rather than failing.
        if HermesDeepLink.isNewChatInProfileURL(url) {
            pendingNewChatRequest = NewChatRequest(
                profileName: HermesDeepLink.profileName(fromNewChatInProfile: url)
            )
            return
        }

        if HermesDeepLink.isNewChatURL(url) {
            pendingNewChatRequest = NewChatRequest(autoStartsVoiceInput: false)
            return
        }

        if let sessionID = HermesDeepLink.sessionID(from: url) {
            pendingDeepLinkedSessionID = sessionID
            return
        }

        guard HermesShareDraft.isShareOpenURL(url) else {
            return
        }

        importPendingSharedDraftIfAvailable()
    }

    /// Routes a deep link queued by an App Intent through the same `handleOpenURL` parser
    /// used for external URLs, then clears it so it routes exactly once (#337).
    private func drainPendingIntentDeepLink() {
        guard let url = intentRouter.pendingDeepLink else { return }
        intentRouter.pendingDeepLink = nil
        handleOpenURL(url)
    }

    private func importPendingSharedDraftIfAvailable() {
        guard let directory = HermesShareDraft.containerURL() else {
            return
        }

        do {
            if let sharedImport = try HermesShareDraft.loadPendingImport(from: directory) {
                pendingSharedImport = sharedImport
            }
        } catch {
            pendingSharedImport = nil
        }
    }
}

#Preview {
    ContentView(authManager: AuthManager())
}
