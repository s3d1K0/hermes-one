import AVFoundation
import Foundation
import UIKit

/// Capture micro + lecture PCM pour le mode vocal "One", porte depuis
/// VisionClaw (samples/CameraAccess/CameraAccess/Gemini/AudioManager.swift).
/// Audio uniquement : pas de SDK Meta DAT, pas de video. L'audio des lunettes
/// passe par le Bluetooth HFP standard via AVAudioSession.
final class OneAudioController {
    var onAudioCaptured: ((Data) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isCapturing = false
    private var wasCapturingBeforeInterruption = false

    // Accumule le PCM reechantillonne en paquets d'environ 100ms avant envoi.
    private let sendQueue = DispatchQueue(label: "one.audio.accumulator")
    private var accumulatedData = Data()
    private let minSendBytes = 3200  // 100ms a 16kHz mono Int16 = 1600 frames * 2 octets

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    func setupSession() throws {
        let session = AVAudioSession.sharedInstance()
        // voiceChat : AEC agressif (micro + haut-parleur co-localises sur l'iPhone),
        // utilise quand le reglage "Sortie haut-parleur" force l'audio sur le
        // telephone. videoChat : AEC modere (micro sur les lunettes, haut-parleur
        // sur les lunettes), le cas par defaut. Valeurs reprises de VisionClaw.
        let forceSpeaker = OneSettings.speakerOutputEnabled
        if forceSpeaker {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
        } else {
            try session.setCategory(
                .playAndRecord,
                mode: .videoChat,
                options: [.allowBluetoothHFP, .mixWithOthers, .defaultToSpeaker]
            )
        }
        try session.setPreferredSampleRate(OneConfig.inputAudioSampleRate)
        try session.setPreferredIOBufferDuration(0.064)
        try session.setActive(true)
        if forceSpeaker {
            try? session.overrideOutputAudioPort(.speaker)
        }

        setupInterruptionHandling()
    }

    func startCapture() throws {
        guard !isCapturing else { return }

        audioEngine.attach(playerNode)
        let playerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: OneConfig.outputAudioSampleRate,
            channels: OneConfig.audioChannels,
            interleaved: false
        )!
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playerFormat)

        let inputNode = audioEngine.inputNode
        let inputNativeFormat = inputNode.outputFormat(forBus: 0)

        // Garde-fou : si la route audio n'est pas encore prete, le format natif
        // a un sampleRate de 0 et installer un tap crasherait. On abandonne
        // proprement plutot que de planter.
        guard inputNativeFormat.sampleRate > 0 else {
            NSLog("[One][Audio] Input format not ready (sampleRate=0), aborting capture start")
            audioEngine.detach(playerNode)
            throw OneAudioError.inputFormatNotReady
        }

        let needsResample =
            inputNativeFormat.sampleRate != OneConfig.inputAudioSampleRate
            || inputNativeFormat.channelCount != OneConfig.audioChannels

        sendQueue.async { self.accumulatedData = Data() }

        var converter: AVAudioConverter?
        let resampleFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: OneConfig.inputAudioSampleRate,
            channels: OneConfig.audioChannels,
            interleaved: false
        )!
        if needsResample {
            converter = AVAudioConverter(from: inputNativeFormat, to: resampleFormat)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputNativeFormat) {
            [weak self] buffer, _ in
            guard let self else { return }

            let pcmData: Data
            if let converter {
                guard
                    let resampled = self.convertBuffer(
                        buffer, using: converter, targetFormat: resampleFormat)
                else { return }
                pcmData = self.float32BufferToInt16Data(resampled)
            } else {
                pcmData = self.float32BufferToInt16Data(buffer)
            }

            self.sendQueue.async {
                self.accumulatedData.append(pcmData)
                if self.accumulatedData.count >= self.minSendBytes {
                    let chunk = self.accumulatedData
                    self.accumulatedData = Data()
                    self.onAudioCaptured?(chunk)
                }
            }
        }

        try audioEngine.start()
        playerNode.play()
        isCapturing = true
    }

    func playAudio(_ data: Data) {
        guard isCapturing, !data.isEmpty else { return }

        let playerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: OneConfig.outputAudioSampleRate,
            channels: OneConfig.audioChannels,
            interleaved: false
        )!

        let frameCount =
            UInt32(data.count) / (OneConfig.audioBitsPerSample / 8 * OneConfig.audioChannels)
        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: frameCount)
        else { return }
        buffer.frameLength = frameCount

        guard let floatData = buffer.floatChannelData else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<Int(frameCount) {
                floatData[0][i] = Float(int16Ptr[i]) / Float(Int16.max)
            }
        }

        playerNode.scheduleBuffer(buffer)
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    func stopPlayback() {
        playerNode.stop()
        playerNode.play()
    }

    func stopCapture() {
        guard isCapturing else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        audioEngine.stop()
        audioEngine.detach(playerNode)
        isCapturing = false
        sendQueue.async {
            if !self.accumulatedData.isEmpty {
                let chunk = self.accumulatedData
                self.accumulatedData = Data()
                self.onAudioCaptured?(chunk)
            }
        }
        removeObservers()
    }

    // MARK: - Interruptions & changements de route

    private func setupInterruptionHandling() {
        // Idempotent : setupSession() peut etre rappele (attemptAudioReset), on
        // repart d'observers propres pour ne pas empiler les callbacks.
        removeObservers()

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self,
                let userInfo = notification.userInfo,
                let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }

            switch type {
            case .began:
                self.wasCapturingBeforeInterruption = self.isCapturing
                if self.isCapturing {
                    self.audioEngine.pause()
                }
            case .ended:
                if self.wasCapturingBeforeInterruption {
                    self.resumeAudioAfterInterruption()
                }
            @unknown default:
                break
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self,
                let userInfo = notification.userInfo,
                let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
            else { return }

            if reason == .oldDeviceUnavailable {
                // Lunettes BT / casque deconnecte : la route capture disparait,
                // on reconstruit proprement la session + le tap.
                NSLog("[One][Audio] Audio device removed")
                if self.isCapturing {
                    self.attemptAudioReset()
                }
            }
        }

        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            // Le media server a redemarre : toutes les ressources audio sont
            // invalides, on doit tout reconstruire.
            NSLog("[One][Audio] Media services were reset")
            self?.attemptAudioReset()
        }

        setupAppLifecycleObservers()
    }

    private func setupAppLifecycleObservers() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Le moteur audio peut avoir ete stoppe par iOS pendant que l'app
            // etait en arriere-plan ; on relance si necessaire au retour.
            if self.isCapturing && !self.audioEngine.isRunning {
                NSLog("[One][Audio] Audio engine stopped while backgrounded, attempting reset")
                self.attemptAudioReset()
            }
        }
    }

    /// Relance l'audio apres une interruption (appel, Siri...). Si la relance
    /// directe echoue, reconstruit toute la session en dernier recours.
    private func resumeAudioAfterInterruption() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
            try audioEngine.start()
        } catch {
            NSLog("[One][Audio] Failed to resume audio: %@", error.localizedDescription)
            attemptAudioReset()
        }
    }

    /// Reconstruction complete du pipeline audio : stoppe le moteur, retire le
    /// tap, puis re-cree la session et redemarre la capture avec le garde-fou
    /// de format. Porte de VisionClaw AudioManager.attemptAudioReset().
    private func attemptAudioReset() {
        NSLog("[One][Audio] Attempting audio reset")
        let wasCapturing = isCapturing

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        isCapturing = false

        guard wasCapturing else { return }

        do {
            try setupSession()
            try startCapture()
            NSLog("[One][Audio] Audio reset successful")
        } catch {
            NSLog("[One][Audio] Audio reset failed: %@", error.localizedDescription)
        }
    }

    private func removeObservers() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
        if let observer = mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(observer)
            mediaServicesResetObserver = nil
        }
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
    }

    // MARK: - Helpers prive

    private func float32BufferToInt16Data(_ buffer: AVAudioPCMBuffer) -> Data {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let floatData = buffer.floatChannelData else { return Data() }
        var int16Array = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let sample = max(-1.0, min(1.0, floatData[0][i]))
            int16Array[i] = Int16(sample * Float(Int16.max))
        }
        return int16Array.withUnsafeBufferPointer { ptr in
            Data(buffer: ptr)
        }
    }

    private func convertBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = UInt32(Double(inputBuffer.frameLength) * ratio)
        guard outputFrameCount > 0 else { return nil }

        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: outputFrameCount)
        else {
            return nil
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if error != nil {
            return nil
        }

        return outputBuffer
    }
}

enum OneAudioError: Error {
    case inputFormatNotReady
}
