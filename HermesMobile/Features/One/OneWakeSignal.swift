//
// OneWakeSignal.swift
//
// [One] Canal minimal widget / Centre de controle -> app via l'App Group hermex.
// Le widget (hors process) pose un flag dans les UserDefaults partages ; l'app le
// consomme quand elle repasse au premier plan et presente l'overlay vocal One.
// Ce fichier est membre de la target app ET de la target widget.
//
// Porte depuis VisionClaw (Gemini/WakeSignal.swift). On reutilise l'App Group
// existant de hermex (cle Info.plist `HermesAppGroupIdentifier`, defaut
// `group.com.uzairansar.hermesmobile`) plutot que d'en creer un nouveau.
//

import Foundation

enum OneWakeSignal {
    /// Meme resolution que `HermesShareDraft.appGroupIdentifier`, mais dupliquee
    /// ici pour rester sans dependance (ce fichier est aussi compile dans la
    /// target widget, ou `HermesShareDraft` n'est pas membre). Les deux process
    /// (app + widget) lisent la meme cle Info.plist, donc pointent sur le meme
    /// suite d'UserDefaults partage.
    private static var suiteName: String {
        Bundle.main.object(forInfoDictionaryKey: "HermesAppGroupIdentifier") as? String
            ?? "group.com.uzairansar.hermesmobile"
    }

    private static let key = "oneWakeRequestedAt"

    /// Appele depuis l'App Intent (widget / Centre de controle). Pose l'horodatage
    /// du reveil demande dans l'App Group et poste la notification locale pour le
    /// cas ou l'app est deja au premier plan (warm).
    static func request() {
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(Date().timeIntervalSince1970, forKey: key)
        NotificationCenter.default.post(name: .oneWakeRequested, object: nil)
    }

    /// Appele par l'app au premier plan : true si un reveil est en attente. Purge
    /// le flag pour ne reveiller qu'une fois.
    static func consume() -> Bool {
        let defaults = UserDefaults(suiteName: suiteName)
        guard let ts = defaults?.double(forKey: key), ts > 0 else { return false }
        defaults?.removeObject(forKey: key)
        return true
    }
}

extension Notification.Name {
    /// Poste par `OneWakeSignal.request()` (App Intent) pour le cas warm.
    static let oneWakeRequested = Notification.Name("oneWakeRequested")
}
