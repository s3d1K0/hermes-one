//
// OneActivationIntent.swift
//
// [One] App Intent « Parler a One » : declenche depuis le widget ecran verrouille,
// le Centre de controle (iOS 18) ou l'app Raccourcis. Ouvre l'app au premier plan
// (`openAppWhenRun = true`) et pose le flag de reveil (OneWakeSignal), que
// `ContentView` consomme au retour au premier plan pour presenter l'overlay vocal.
// Ce fichier est membre de la target app ET de la target widget.
//
// Porte depuis VisionClaw (Gemini/HermesActivationIntent.swift).
//

import AppIntents

struct OneActivationIntent: AppIntent {
    static var title: LocalizedStringResource = "Parler a One"
    static var description = IntentDescription("Ouvre l'assistant vocal One.")

    // [One] Ouvre l'app : garantit que `ContentView` est vivant pour consumer le
    // flag de reveil au premier plan (openAppWhenRun=false ne marchait pas si
    // l'app dormait -> cf. VisionClaw).
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        OneWakeSignal.request()
        return .result()
    }
}
