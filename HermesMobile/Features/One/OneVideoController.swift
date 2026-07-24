import Foundation
import MWDATCamera
import MWDATCore
import UIKit

/// Etat du flux video lunettes.
enum OneVideoStreamState: Equatable {
    case stopped
    case waiting
    case streaming
    case error(String)
}

/// Capture video depuis les lunettes Meta (Meta Wearables DAT SDK) et transmet les
/// frames (throttlees) a Gemini Live via `onVideoFrame`, porte depuis VisionClaw
/// (samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift).
///
/// Adapte a l'API MWDATCamera >= 0.8 (resolue par le SPM upToNextMajor depuis 0.4.0) :
/// VisionClaw pinnait 0.4.0 ou le flux s'ouvrait via `StreamSession(streamSessionConfig:
/// deviceSelector:)`. En 0.8.x cette classe a disparu au profit de
/// `DeviceSession.addStream(config:)` (cf. MWDATCore.DeviceSession + l'extension
/// MWDATCamera). Simplifie par rapport a l'original : pas de decodage HEVC arriere-plan
/// (VideoDecoder/VTDecompressionSession), pas de capture photo, pas de mode camera iPhone --
/// uniquement le flux premier plan des lunettes, throttle et transmis a Gemini.
@MainActor
final class OneVideoController {
    private(set) var state: OneVideoStreamState = .stopped

    /// Frame decodee (deja throttlee a `OneConfig.videoFrameInterval`), a transmettre a Gemini.
    var onVideoFrame: ((UIImage) -> Void)?

    private let wearables: WearablesInterface
    private let deviceSelector: AutoDeviceSelector
    private var deviceSession: DeviceSession?
    private var stream: MWDATCamera.Stream?

    private var stateListenerToken: (any AnyListenerToken)?
    private var videoFrameListenerToken: (any AnyListenerToken)?
    private var errorListenerToken: (any AnyListenerToken)?

    private var lastFrameTime: Date = .distantPast

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    }

    /// Demande la permission camera puis ouvre une session lunettes + un flux video bas debit.
    /// Tolerant : si aucune lunette n'est appairee (ou en simulateur sans mock device), l'erreur
    /// est reportee dans `state` sans jamais crasher -- le pipeline vocal continue sans video.
    func start() async {
        guard state == .stopped else { return }
        state = .waiting

        do {
            let status = try await wearables.checkPermissionStatus(.camera)
            if status != .granted {
                let requested = try await wearables.requestPermission(.camera)
                guard requested == .granted else {
                    state = .error("Permission camera refusee")
                    return
                }
            }
        } catch {
            state = .error("Erreur permission camera: \(error.description)")
            return
        }

        do {
            let session = try wearables.createSession(deviceSelector: deviceSelector)
            deviceSession = session
            try session.start()

            let config = StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 24)
            guard let stream = try session.addStream(config: config) else {
                state = .error("Impossible d'ouvrir le flux video")
                return
            }
            self.stream = stream
            attachListeners(to: stream)
            stream.start()
        } catch {
            state = .error("Erreur session lunettes: \(error.description)")
        }
    }

    func stop() {
        stream?.stop()
        deviceSession?.stop()
        stream = nil
        deviceSession = nil
        state = .stopped
    }

    // MARK: - Private

    private func attachListeners(to stream: MWDATCamera.Stream) {
        stateListenerToken = stream.statePublisher.listen { [weak self] streamState in
            Task { @MainActor [weak self] in
                self?.updateState(from: streamState)
            }
        }

        videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] videoFrame in
            Task { @MainActor [weak self] in
                guard let self, let image = videoFrame.makeUIImage() else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastFrameTime) >= OneConfig.videoFrameInterval else { return }
                self.lastFrameTime = now
                self.onVideoFrame?(image)
            }
        }

        errorListenerToken = stream.errorPublisher.listen { [weak self] streamError in
            Task { @MainActor [weak self] in
                self?.state = .error(streamError.description)
            }
        }
    }

    private func updateState(from streamState: StreamState) {
        switch streamState {
        case .stopped, .stopping:
            state = .stopped
        case .waitingForDevice, .starting, .paused:
            state = .waiting
        case .streaming:
            state = .streaming
        }
    }
}
