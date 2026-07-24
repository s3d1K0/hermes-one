import Foundation

/// Modeles d'appel d'outil Gemini Live, portes depuis VisionClaw
/// (samples/CameraAccess/CameraAccess/OpenClaw/ToolCallModels.swift).
/// Gemini n'a qu'un seul outil (`execute`) : chaque appel est delegue au
/// gateway Hermes (OneHermesBridge) via OneToolCallRouter.

// MARK: - Appel d'outil Gemini (parse depuis le JSON serveur)

struct OneFunctionCall {
    let id: String
    let name: String
    let args: [String: Any]
}

struct OneToolCall {
    let functionCalls: [OneFunctionCall]

    init?(json: [String: Any]) {
        guard let toolCall = json["toolCall"] as? [String: Any],
            let calls = toolCall["functionCalls"] as? [[String: Any]]
        else {
            return nil
        }
        self.functionCalls = calls.compactMap { call in
            guard let id = call["id"] as? String,
                let name = call["name"] as? String
            else { return nil }
            let args = call["args"] as? [String: Any] ?? [:]
            return OneFunctionCall(id: id, name: name, args: args)
        }
    }
}

// MARK: - Annulation d'appel d'outil Gemini

struct OneToolCallCancellation {
    let ids: [String]

    init?(json: [String: Any]) {
        guard let cancellation = json["toolCallCancellation"] as? [String: Any],
            let ids = cancellation["ids"] as? [String]
        else {
            return nil
        }
        self.ids = ids
    }
}

// MARK: - Resultat d'outil

enum OneToolResult {
    case success(String)
    case failure(String)

    var responseValue: [String: Any] {
        switch self {
        case .success(let result):
            return ["result": result]
        case .failure(let error):
            return ["error": error]
        }
    }
}

// MARK: - Statut d'appel d'outil (pour l'UI)

enum OneToolCallStatus: Equatable {
    case idle
    case executing(String)
    case completed(String)
    case failed(String, String)
    case cancelled(String)

    var displayText: String {
        switch self {
        case .idle: return ""
        case .executing(let name): return "Running: \(name)..."
        case .completed(let name): return "Done: \(name)"
        case .failed(let name, let err): return "Failed: \(name) - \(err)"
        case .cancelled(let name): return "Cancelled: \(name)"
        }
    }

    var isActive: Bool {
        if case .executing = self { return true }
        return false
    }
}

// MARK: - Declarations d'outils (message setup Gemini)

enum OneToolDeclarations {

    /// Outils exposes a Gemini Live : le petit set RAPIDE gere localement
    /// (OneLocalTools : heure, minuteur, rappel) + l'outil `execute` de delegation
    /// a Hermes pour tout le reste. Le dispatch local vs delegation vit dans
    /// OneToolCallRouter (source de verite des noms locaux : OneLocalTools.toolNames).
    static func allDeclarations() -> [[String: Any]] {
        return [getCurrentTime, setTimer, setReminder, execute]
    }

    // MARK: - Outils rapides locaux (fast-path, JAMAIS delegues a Hermes)

    static let getCurrentTime: [String: Any] = [
        "name": "get_current_time",
        "description": "Donne la date et l'heure locales actuelles, instantanement. Utilise-le pour toute question sur l'heure ou la date du jour au lieu de deviner ou de deleguer.",
        "parameters": [
            "type": "object",
            "properties": [:] as [String: Any],
        ] as [String: Any],
        "behavior": "BLOCKING",
    ]

    static let setTimer: [String: Any] = [
        "name": "set_timer",
        "description": "Declenche un minuteur local : une notification apres un delai en secondes. Utilise-le pour les minuteurs simples (\"minuteur de 5 minutes\", \"previens-moi dans 30 secondes\").",
        "parameters": [
            "type": "object",
            "properties": [
                "seconds": [
                    "type": "number",
                    "description": "Duree du minuteur en secondes (>= 1). Convertis les minutes/heures en secondes.",
                ],
                "label": [
                    "type": "string",
                    "description": "Libelle court affiche dans la notification (ex: \"Pates\", \"Pause\"). Optionnel.",
                ],
            ] as [String: Any],
            "required": ["seconds"],
        ] as [String: Any],
        "behavior": "BLOCKING",
    ]

    static let setReminder: [String: Any] = [
        "name": "set_reminder",
        "description": "Programme un rappel local a une heure/date donnee (notification). Utilise-le pour \"rappelle-moi a 15h\", \"rappelle-moi demain matin\". Pour l'heure courante, appelle d'abord get_current_time si besoin de calculer la date cible.",
        "parameters": [
            "type": "object",
            "properties": [
                "datetime": [
                    "type": "string",
                    "description": "Date et heure du rappel en heure LOCALE, au format ISO 8601 (ex: \"2026-07-24T15:00:00\"). Alternative: fournis 'seconds_from_now'.",
                ],
                "seconds_from_now": [
                    "type": "number",
                    "description": "Delai relatif en secondes avant le rappel, si tu prefreres au datetime. Optionnel.",
                ],
                "label": [
                    "type": "string",
                    "description": "Texte du rappel affiche dans la notification (ex: \"Appeler le dentiste\").",
                ],
            ] as [String: Any],
            "required": ["label"],
        ] as [String: Any],
        "behavior": "BLOCKING",
    ]

    static let execute: [String: Any] = [
        "name": "execute",
        "description": "Your only way to take action. You have no memory, storage, or ability to do anything on your own -- use this tool for everything: sending messages, searching the web, adding to lists, setting reminders, creating notes, research, drafts, scheduling, smart home control, app interactions, or any request that goes beyond answering a question. When in doubt, use this tool.",
        "parameters": [
            "type": "object",
            "properties": [
                "task": [
                    "type": "string",
                    "description": "Clear, detailed description of what to do. Include all relevant context: names, content, platforms, quantities, etc.",
                ]
            ],
            "required": ["task"],
        ] as [String: Any],
        "behavior": "BLOCKING",
    ]
}
