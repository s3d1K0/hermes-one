import Foundation
import MWDATCore

#if canImport(MWDATMockDevice)
    import MWDATMockDevice
#endif

/// Connexion aux lunettes Meta (Meta Wearables DAT SDK), portee depuis VisionClaw
/// (samples/CameraAccess/CameraAccess/ViewModels/WearablesViewModel.swift). Version
/// simplifiee : pas de sheet "Getting Started" / d'alerte de compatibilite (pas
/// d'UI dediee cote One pour l'instant) -- juste l'etat d'enregistrement et la
/// liste d'appareils, consommes par OneVideoController pour ouvrir un flux video.
///
/// NB API : porte contre meta-wearables-dat-ios >= 0.8 (resolu via upToNextMajor
/// depuis 0.4.0). `Wearables`/`WearablesInterface`/`RegistrationState` sont restes
/// stables depuis l'app VisionClaw de reference ; seule l'API de streaming
/// (MWDATCamera) a change entre 0.4.x et 0.8.x, geree par OneVideoController.
@MainActor
final class OneWearablesController {
    private(set) var registrationState: RegistrationState
    private(set) var devices: [DeviceIdentifier]
    private(set) var hasMockDevice: Bool = false

    /// Instance partagee du SDK DAT, reutilisee par OneVideoController (AutoDeviceSelector,
    /// createSession).
    let wearables: WearablesInterface

    private var registrationTask: Task<Void, Never>?
    private var deviceStreamTask: Task<Void, Never>?

    /// `Wearables.configure()` doit etre appele une seule fois par process. Protege
    /// par un flag statique au cas ou plusieurs controleurs seraient instancies.
    private static var didConfigure = false

    init() {
        if !Self.didConfigure {
            Self.didConfigure = true
            do {
                try Wearables.configure()
            } catch {
                NSLog("[OneWearablesController] Wearables.configure failed: %@", error.description)
            }
        }

        let wearables = Wearables.shared
        self.wearables = wearables
        self.registrationState = wearables.registrationState
        self.devices = wearables.devices

        registrationTask = Task { [weak self] in
            guard let self else { return }
            for await state in wearables.registrationStateStream() {
                self.registrationState = state
            }
        }

        deviceStreamTask = Task { [weak self] in
            guard let self else { return }
            for await devices in wearables.devicesStream() {
                self.devices = devices
                #if canImport(MWDATMockDevice)
                    self.hasMockDevice = !MockDeviceKit.shared.pairedDevices.isEmpty
                #endif
            }
        }
    }

    deinit {
        registrationTask?.cancel()
        deviceStreamTask?.cancel()
    }

    var isRegistered: Bool { registrationState == .registered }
    var hasDevice: Bool { !devices.isEmpty }

    /// Lance le flux d'appairage (ouvre l'app Meta AI). Porte depuis
    /// WearablesViewModel.connectGlasses().
    func connectGlasses() async {
        guard registrationState != .registering else { return }
        do {
            try await wearables.startRegistration()
        } catch {
            NSLog("[OneWearablesController] startRegistration failed: %@", error.description)
        }
    }

    /// Porte depuis WearablesViewModel.disconnectGlasses().
    func disconnectGlasses() async {
        do {
            try await wearables.startUnregistration()
        } catch {
            NSLog("[OneWearablesController] startUnregistration failed: %@", error.description)
        }
    }
}
