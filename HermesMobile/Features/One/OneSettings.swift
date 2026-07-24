import Foundation

/// Reglages persistants du mode vocal "One", portes depuis VisionClaw
/// (samples/CameraAccess/CameraAccess/Settings/SettingsManager.swift). Les
/// toggles/textes non sensibles vivent dans UserDefaults sous les memes cles
/// que les `@AppStorage` de SettingsView ; la cle API Gemini est un secret et
/// vit dans le Keychain (KeychainStore, style hermex), avec repli sur
/// `OneSecrets.geminiAPIKey` (dev local, fichier gitignore) si rien n'est
/// enregistre.
enum OneSettings {
    // MARK: - Cles UserDefaults (les memes valeurs alimentent les `@AppStorage` de SettingsView)

    static let geminiSystemPromptKey = "one.geminiSystemPrompt"
    static let speakerOutputEnabledKey = "one.speakerOutputEnabled"
    static let videoStreamingEnabledKey = "one.videoStreamingEnabled"
    static let proactiveNotificationsEnabledKey = "one.proactiveNotificationsEnabled"
    static let autoStandbySecondsKey = "one.autoStandbySeconds"
    static let gatewayHostKey = "one.gatewayHost"
    static let gatewayPortKey = "one.gatewayPort"

    static let defaultAutoStandbySeconds = 180

    private static var defaults: UserDefaults { .standard }

    // MARK: - Gemini system prompt

    /// Prompt systeme envoye a Gemini Live. Vide (jamais configure) retombe
    /// sur `OneConfig.defaultSystemInstruction`.
    static var geminiSystemPrompt: String {
        get {
            let stored = defaults.string(forKey: geminiSystemPromptKey) ?? ""
            return stored.isEmpty ? OneConfig.defaultSystemInstruction : stored
        }
        set { defaults.set(newValue, forKey: geminiSystemPromptKey) }
    }

    // MARK: - Gemini API key (Keychain, secret)

    /// Charge la cle API Gemini Live depuis le Keychain ; repli sur
    /// `OneSecrets.geminiAPIKey` si rien n'est enregistre. Les erreurs Keychain
    /// sont avalees (tolerant, style hermex) : au pire on retombe sur le secret local.
    static func geminiAPIKey(keychain: any KeychainStoring = KeychainStore()) -> String {
        let stored = (try? keychain.load(.oneGeminiAPIKey)) ?? nil
        if let stored, !stored.isEmpty {
            return stored
        }
        return OneSecrets.geminiAPIKey
    }

    /// Enregistre la cle API Gemini Live dans le Keychain. Une valeur vide
    /// supprime l'entree (retour au repli `OneSecrets.geminiAPIKey`).
    static func setGeminiAPIKey(_ value: String, keychain: any KeychainStoring = KeychainStore()) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? keychain.delete(.oneGeminiAPIKey)
        } else {
            try? keychain.save(trimmed, forKey: .oneGeminiAPIKey)
        }
    }

    // MARK: - Audio / video / notifications

    /// Force la sortie audio sur le haut-parleur de l'iPhone (au lieu des lunettes).
    static var speakerOutputEnabled: Bool {
        get { defaults.bool(forKey: speakerOutputEnabledKey) }
        set { defaults.set(newValue, forKey: speakerOutputEnabledKey) }
    }

    /// Active l'envoi video (lunettes -> Gemini) pendant une session vocale, via
    /// OneVideoController (cf. OneVoiceSessionViewModel.start()).
    static var videoStreamingEnabled: Bool {
        get { defaults.object(forKey: videoStreamingEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: videoStreamingEnabledKey) }
    }

    /// Active le canal d'evenements du gateway Hermes (push proactif) : quand
    /// vrai, `OneVoiceSessionViewModel` se connecte a `OneEventClient` et reveille
    /// Gemini pour lire les heartbeats/cron pousses (cf. deliverProactive).
    static var proactiveNotificationsEnabled: Bool {
        get { defaults.object(forKey: proactiveNotificationsEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: proactiveNotificationsEnabledKey) }
    }

    // MARK: - Gateway Hermes (push proactif, secret cote jeton)

    /// Hote du gateway Hermes (OpenClaw) pour le canal d'evenements proactif.
    /// Non sensible : vit dans UserDefaults, repli sur `OneSecrets.gatewayHost`.
    static var gatewayHost: String {
        get {
            let stored = defaults.string(forKey: gatewayHostKey) ?? ""
            return stored.isEmpty ? OneSecrets.gatewayHost : stored
        }
        set { defaults.set(newValue, forKey: gatewayHostKey) }
    }

    /// Port du gateway Hermes (OpenClaw). Repli sur `OneSecrets.gatewayPort`.
    static var gatewayPort: Int {
        get {
            let stored = defaults.integer(forKey: gatewayPortKey)
            return stored != 0 ? stored : OneSecrets.gatewayPort
        }
        set { defaults.set(newValue, forKey: gatewayPortKey) }
    }

    /// Charge le jeton du gateway Hermes (OpenClaw) depuis le Keychain (secret,
    /// comme la cle API Gemini) ; repli sur `OneSecrets.gatewayToken`.
    static func gatewayToken(keychain: any KeychainStoring = KeychainStore()) -> String {
        let stored = (try? keychain.load(.oneGatewayToken)) ?? nil
        if let stored, !stored.isEmpty {
            return stored
        }
        return OneSecrets.gatewayToken
    }

    /// Enregistre le jeton du gateway Hermes dans le Keychain. Une valeur vide
    /// supprime l'entree (retour au repli `OneSecrets.gatewayToken`).
    static func setGatewayToken(_ value: String, keychain: any KeychainStoring = KeychainStore()) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? keychain.delete(.oneGatewayToken)
        } else {
            try? keychain.save(trimmed, forKey: .oneGatewayToken)
        }
    }

    // MARK: - Veille auto

    /// Delai d'inactivite (secondes) avant mise en veille automatique de One.
    /// Reserve pour un futur minuteur de veille (pas encore porte dans ce module).
    static var autoStandbySeconds: Int {
        get {
            let stored = defaults.integer(forKey: autoStandbySecondsKey)
            return stored != 0 ? stored : defaultAutoStandbySeconds
        }
        set { defaults.set(newValue, forKey: autoStandbySecondsKey) }
    }
}
