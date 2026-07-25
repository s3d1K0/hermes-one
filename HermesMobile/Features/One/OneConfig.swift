import CoreGraphics
import Foundation

/// Configuration du mode vocal "One" (Gemini Live), porte depuis VisionClaw
/// (samples/CameraAccess/CameraAccess/Gemini/GeminiConfig.swift). `videoFrameInterval`
/// et `videoJPEGQuality` alimentent OneVideoController/OneGeminiLiveClient.sendVideoFrame
/// (pipeline video lunettes, actif si OneSettings.videoStreamingEnabled). Le pont vers
/// le gateway Hermes (delegation d'outils Gemini `execute`) vit dans
/// OneHermesBridge/OneToolCallRouter.
enum OneConfig {
    static let websocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    static let model = "models/gemini-2.5-flash-native-audio-preview-12-2025"

    static let inputAudioSampleRate: Double = 16000
    static let outputAudioSampleRate: Double = 24000
    static let audioChannels: UInt32 = 1
    static let audioBitsPerSample: UInt32 = 16

    static let videoFrameInterval: TimeInterval = 1.0
    static let videoJPEGQuality: CGFloat = 0.5

    /// Prompt systeme effectivement utilise : le reglage utilisateur (Reglages > One)
    /// s'il existe, sinon `defaultSystemInstruction`. Lu a chaque connexion, pas mis en cache.
    static var systemInstruction: String { OneSettings.geminiSystemPrompt }

    static let defaultSystemInstruction = """
        Tu es l'assistant vocal de Sedik, qui porte des lunettes connectees Meta Ray-Ban. Tu vois par sa camera et tu lui parles. Reponses courtes, naturelles, a l'oral, en francais.

        REGLE DE ROUTAGE (en une phrase) : reponds toi-meme (avec la recherche Google si tu as besoin d'info fraiche : meteo, horaires, actu, faits, culture generale) a tout ce qui ne touche NI aux donnees privees de Sedik NI a une action a effet de bord ; pour la memoire, les fichiers, les comptes, l'ecriture/l'envoi, ou une tache multi-etapes -> delegue a Hermes via execute.

        Garde-fous :
        - Info fraiche ou verifiable du monde (meteo, horaires, resultats, actu, faits, definitions) -> utilise la recherche Google integree et reponds toi-meme, ne delegue pas.
        - Ne reponds JAMAIS de toi-meme sur les donnees ou les comptes de Sedik (ses messages, ses notes/listes, ses fichiers, son agenda, ses appareils) : delegue a Hermes via execute.
        - Tout ce qui ecrit, envoie, cree, modifie ou pilote quelque chose (effet de bord), ou toute tache multi-etapes -> execute.

        Outils rapides locaux (utilise-les directement, sans deleguer) :
        - get_current_time pour l'heure ou la date.
        - set_timer pour un minuteur simple ("minuteur de 5 minutes", "previens-moi dans 30 secondes").
        - set_reminder pour un rappel simple a une heure/date donnee ("rappelle-moi a 15h", "rappelle-moi demain").

        execute te connecte a Hermes, un assistant personnel qui peut tout faire sur les donnees et comptes de Sedik : envoyer des messages, gerer des listes et notes durables, ses fichiers, son agenda, piloter la domotique, interagir avec des apps. Sois detaille dans la description de la tache : noms, contenu, plateformes, quantites, tout le contexte utile.

        IMPORTANT : avant d'appeler execute, dis TOUJOURS une breve confirmation a voix haute, par exemple :
        - "Ok, j'ajoute ca a ta liste." puis appelle execute.
        - "C'est parti, je m'en occupe." puis appelle execute.
        - "D'accord, j'envoie le message." puis appelle execute.
        N'appelle jamais execute en silence : Sedik doit savoir que tu l'as entendu et que tu agis, l'outil peut prendre quelques secondes.

        Pour un message, confirme le destinataire et le contenu avant de deleguer, sauf urgence evidente. Ne pretends jamais faire toi-meme ce qui passe par execute.
        """

    /// Cle API Gemini Live effective : le reglage utilisateur (Keychain, Reglages > One)
    /// s'il existe, sinon `OneSecrets.geminiAPIKey` (dev local, fichier gitignore).
    static var apiKey: String { OneSettings.geminiAPIKey() }

    static var liveURL: URL? {
        guard isConfigured else { return nil }
        return URL(string: "\(websocketBaseURL)?key=\(apiKey)")
    }

    static var isConfigured: Bool {
        apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty
    }

    // MARK: - Gateway Hermes (push proactif, OpenClaw)

    /// Hote/port/jeton du canal d'evenements du gateway Hermes (heartbeat/cron),
    /// portes depuis VisionClaw (GeminiConfig.openClawHost/openClawPort/
    /// openClawGatewayToken). Reglage utilisateur (Reglages > One) s'il existe,
    /// sinon `OneSecrets` (dev local, fichier gitignore).
    static var gatewayHost: String { OneSettings.gatewayHost }
    static var gatewayPort: Int { OneSettings.gatewayPort }
    static var gatewayToken: String { OneSettings.gatewayToken() }

    static var isGatewayConfigured: Bool {
        gatewayToken != "YOUR_OPENCLAW_GATEWAY_TOKEN" && !gatewayToken.isEmpty
            && gatewayHost != "http://YOUR_MAC_HOSTNAME.local"
    }
}
