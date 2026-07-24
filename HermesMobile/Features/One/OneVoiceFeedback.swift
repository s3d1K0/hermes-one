//
// OneVoiceFeedback.swift
//
// Retour vocal court ("One active" / "One desactive") pour que l'utilisateur
// sache si One tient le micro ou non. Synthese on-device (AVSpeechSynthesizer),
// routee vers les lunettes via une session .playAndRecord partagee
// (allowBluetoothHFP + mixWithOthers). Porte depuis VisionClaw
// (samples/CameraAccess/CameraAccess/Gemini/VoiceFeedback.swift).
//
// Un completion optionnel permet d'enchainer une action une fois la phrase
// terminee (ex : liberer la session audio seulement apres avoir dit
// "One desactive").
//

import AVFoundation
import Foundation

final class OneVoiceFeedback: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var completion: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Prononce `text` (fr-FR) puis appelle `completion` sur le main thread.
    /// Route vers les lunettes via HFP (meme config que la voix de Gemini dans
    /// OneAudioController) : sans ca, le TTS sort sur le haut-parleur du telephone.
    func say(_ text: String, then completion: (() -> Void)? = nil) {
        self.completion = completion
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord, mode: .voiceChat,
            options: [.allowBluetoothHFP, .mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "fr-FR")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        let callback = completion
        completion = nil
        DispatchQueue.main.async { callback?() }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        let callback = completion
        completion = nil
        DispatchQueue.main.async { callback?() }
    }
}
