# One — Fermeture des gaps (vague 2) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: exécution via workflow ultracode (fan-out audit/verify) ou subagent-driven-development, une tâche à la fois, build-vérifiée. Steps en `- [ ]`.

**Goal:** Rendre le module « One » de `~/Documents/hermes-one` RÉELLEMENT utilisable (pas juste compilable) en fermant les gaps trouvés par la review de complétude (Fable + adversarial) : config gateway en UI, canal proactif persistant, appairage lunettes, régressions audio, veille auto, réveil externe.

**Architecture:** Le socle One est déjà porté de VisionClaw dans `HermesMobile/Features/One/` (14 fichiers, build OK, commits `a4beb1b`..`cf19d63` sur `s3d1K0/hermes-one` master). Cette vague CORRIGE et COMPLÈTE : elle ajoute des champs de réglages, remonte le cycle de vie du canal proactif au niveau app, ajoute une UI d'appairage, et rétablit 2 garde-fous audio supprimés au port. Source de référence pour tout comportement à rétablir = VisionClaw `~/Documents/VisionClaw/samples/CameraAccess/CameraAccess/`.

**Tech Stack:** Swift, SwiftUI `@Observable`/`@MainActor` (style hermex), SwiftData, AVFoundation, `URLSessionWebSocketTask`, Keychain (KeychainAccess), SDK Meta DAT (déjà lié, 0.8.0), App Intents + widget (infra hermex existante : `HermesLiveActivityWidget`, `AppIntents/HermexAppIntents.swift`, App Group `HermesAppGroupIdentifier`).

## Global Constraints

- **Repo** : `~/Documents/hermes-one` (fork `s3d1K0/hermes-one`, `upstream`=hermex). C'est NOTRE fork perso : committer sur `master`, PAS de branche (le CLAUDE.md hermex interdit master/push mais c'est LEVÉ par le propriétaire Sedik ; dire ça à chaque subagent).
- **Source de référence** : `~/Documents/VisionClaw/samples/CameraAccess/CameraAccess/` (VisionClaw, code d'origine des comportements à rétablir).
- **Aucune nouvelle dépendance SPM** (tout est déjà là).
- **Style** : `@Observable`/`@MainActor`, Keychain pour secrets, décodage Codable tolérant, réutiliser les composants réglages hermex (`SettingsCard`, `SettingsToggleRow`, `SettingsPickerRow`).
- **Ne JAMAIS committer** `HermesMobile/Features/One/OneSecrets.swift` (clé Gemini réelle, gitignoré) — vérifier `git status` avant chaque commit.
- **Vérification** = build simulateur sans signature, cache SPM réutilisé :
  `cd ~/Documents/hermes-one && xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -sdk iphonesimulator -configuration Debug build CODE_SIGNING_ALLOWED=NO -skipMacroValidation -clonedSourcePackagesDirPath /private/tmp/claude-501/-Users-s3d1k/a7db1687-ae36-491f-8d10-652a7721f9ed/scratchpad/spm-hermesone 2>&1 | grep -iE "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -20`
  Attendu : `** BUILD SUCCEEDED **`. Nouveau fichier → enregistrer au `project.pbxproj` (PBXBuildFile + PBXFileReference + groupe One + Sources phase ; `plutil -lint` OK). Revert propre si build cassé (`git reset --hard HEAD`), ne jamais laisser le repo cassé.
- **Ordre de priorité** : 1 (gateway UI) et 2 (canal proactif app-level) et 4 (anti-écho) et 5 (récup audio) sont CRITIQUES (le produit ne marche pas sans) ; 3 (appairage) et 6 (veille) et 7 (réveil externe) ensuite ; 8 (mineurs) en dernier.
- **Pas testable sans device/mini** pour la plupart : build-vérifié + revue de fidélité vs VisionClaw = le critère d'acceptation de cette vague.

---

## File Structure

- **Modify** `HermesMobile/Features/Settings/SettingsView.swift` — section « One » : ajouter champs Gateway (Host/Port/Token), bouton appairage lunettes + état, bouton Reset One.
- **Modify** `HermesMobile/Features/One/OneVoiceSessionViewModel.swift` — anti-écho, veille auto (timer), sleepAfterTurn après délégation.
- **Modify** `HermesMobile/Features/One/OneAudioController.swift` — récupération audio (attemptAudioReset + observers).
- **Create** `HermesMobile/Features/One/OneSessionController.swift` — objet app-level qui possède le canal proactif (OneEventClient) + la session, connecté au lancement, indépendant de l'overlay.
- **Modify** `HermesMobile/HermesMobileApp.swift` + `ContentView.swift` — instancier/injecter `OneSessionController`, connecter le canal si configuré, présenter l'overlay au réveil.
- **Modify** `HermesMobile/Features/Chat/ChatView.swift` — utiliser le `OneSessionController` partagé pour l'overlay au lieu d'un `@State` local.
- **Modify** `HermesMobile/Features/One/OneWearablesController.swift` — exposer `registrationState` observable + `connectGlasses`/`disconnectGlasses` publics.
- **Modify/Create** `HermesMobile/AppIntents/*` + `HermesLiveActivityWidget/*` — App Intent + contrôle « Parler à One ».
- **Modify** `HermesMobile/Features/One/OneVideoController.swift` — (mineur) décodage vidéo arrière-plan ou note explicite.
- **Modify** `HermesMobile/Resources/Info.plist` — description micro mentionnant One ; vérif ATS.
- **Modify** `HermesMobile/Features/One/OneSettings.swift` — `resetOneDefaults()`.

---

## Task 1 (CRITIQUE) : Champs Gateway Hermes dans les Réglages

**Pourquoi :** sans host/port/token éditables, délégation + push sont morts sur toute install fraîche (review : « le cœur du produit est mort par défaut »). `OneSettings.gatewayHost/gatewayPort/gatewayToken` + `setGatewayToken` existent déjà mais aucune UI ne les expose.

**Files:** Modify `HermesMobile/Features/Settings/SettingsView.swift` (section « One », ~lignes 485-549).

**Interfaces:** Consomme `OneSettings.gatewayHost` (get/set UserDefaults), `OneSettings.gatewayPort` (get/set), `OneSettings.gatewayToken()`/`setGatewayToken(_:)` (Keychain).

- [ ] **Step 1:** Dans la `SettingsCard("One")`, sous le champ clé Gemini, ajouter 3 lignes : `TextField("Gateway Host", ...)` lié à `OneSettings.gatewayHost` (ex `http://100.84.70.56` ou `http://mac.local`), `TextField("Gateway Port", ...)` (numeric) lié à `gatewayPort`, `SecureField("Gateway Token", ...)` chargé/sauvé via `.task`/`.onChange` sur `OneSettings.gatewayToken()`/`setGatewayToken` (même pattern que la clé Gemini déjà en place). Référence VisionClaw : `Settings/SettingsView.swift` section OpenClaw (4 champs Host/Port/Hook Token/Gateway Token).
- [ ] **Step 2:** Build → BUILD SUCCEEDED, les 3 champs apparaissent dans Réglages > One.
- [ ] **Step 3:** Commit `feat(one): champs gateway Hermes (host/port/token) dans les Reglages` + push master.

---

## Task 2 (CRITIQUE) : Canal proactif + session au niveau app (persistant)

**Pourquoi :** review : « push proactif architecturalement mort ». `OneEventClient` vit dans `OneVoiceSessionViewModel`, lui-même `@State` de l'overlay → connecté seulement overlay ouvert, meurt à la fermeture. Un heartbeat/cron Hermes ne peut jamais réveiller One en usage réel.

**Files:**
- Create `HermesMobile/Features/One/OneSessionController.swift`
- Modify `HermesMobile/HermesMobileApp.swift`, `HermesMobile/ContentView.swift`
- Modify `HermesMobile/Features/Chat/ChatView.swift`, `HermesMobile/Features/One/OneVoiceOverlayView.swift`

**Interfaces:**
- Produces `@Observable @MainActor final class OneSessionController` : possède l'unique `OneVoiceSessionViewModel` (ou l'englobe), `var isOverlayPresented: Bool`, `func connectProactiveChannelIfConfigured()` (branche `OneEventClient` si `proactiveNotificationsEnabled` && `OneConfig.isGatewayConfigured`), `func present()` (ouvre l'overlay), `func onProactivePush(_ text:)` → présente l'overlay + `deliverProactive`.
- Consomme `OneEventClient`, `OneVoiceSessionViewModel`, `OneSettings`.

- [ ] **Step 1:** Créer `OneSessionController` : déplacer l'ownership de `OneEventClient` du ViewModel vers ce controller ; il connecte le canal proactif à l'init si configuré (indépendant de l'overlay). À la réception d'un push : `isOverlayPresented = true` puis délègue au ViewModel `deliverProactive(text)`.
- [ ] **Step 2:** Instancier `OneSessionController` en `@State`/environment au niveau `HermesMobileApp`/`ContentView`, appeler `connectProactiveChannelIfConfigured()` au lancement (et re-évaluer quand les réglages changent).
- [ ] **Step 3:** `ChatView` : remplacer le `@State private var showOne` local par le controller partagé (`.fullScreenCover(isPresented: controller.isOverlayPresented binding)` présentant l'overlay avec le ViewModel du controller). Le bouton composer appelle `controller.present()`.
- [ ] **Step 4:** `OneEventClient` retiré du ViewModel (ou le ViewModel ne le possède plus) ; `deliverProactive` reste sur le ViewModel, piloté par le controller.
- [ ] **Step 5:** Build → SUCCEEDED. Commit `feat(one): controller app-level + canal proactif persistant (push reveille One hors overlay)` + push.

---

## Task 3 (RÉGRESSION) : Garde anti-écho half-duplex

**Pourquoi :** review adversarial HIGH. VisionClaw `GeminiSessionViewModel` (startSession, ~l.149-156) : `let speakerOnPhone = ... || speakerOutputEnabled; if speakerOnPhone && geminiService.isModelSpeaking { return }` avant d'envoyer l'audio capté. Perdu au port → en mode Speaker Output, le micro réinjecte la voix de Gemini = boucle d'écho.

**Files:** Modify `HermesMobile/Features/One/OneVoiceSessionViewModel.swift` (`wireCallbacks`, ~l.142, `audio.onAudioCaptured`).

- [ ] **Step 1:** Dans le closure `audio.onAudioCaptured`, avant `client.sendAudio(data)` :
```swift
      if OneSettings.speakerOutputEnabled && self.client.isModelSpeaking { return }
```
(`client.isModelSpeaking` est déjà `private(set)` lisible.)
- [ ] **Step 2:** Build → SUCCEEDED. Commit `fix(one): garde anti-echo half-duplex en mode speaker (regression)` + push.

---

## Task 4 (RÉGRESSION) : Récupération audio (reset media / foreground / Bluetooth)

**Pourquoi :** review adversarial HIGH. VisionClaw `AudioManager` (~l.252-333) : `attemptAudioReset()` + observers `mediaServicesWereResetNotification`, `willEnterForegroundNotification` (relance si engine arrêté en fond), et `routeChangeNotification`/`.oldDeviceUnavailable` (lunettes BT déconnectées) → reset propre. Le port ne garde QUE l'interruption `.began/.ended` et logue `.oldDeviceUnavailable` sans rien faire.

**Files:** Modify `HermesMobile/Features/One/OneAudioController.swift`.

**Interfaces:** Produces `func attemptAudioReset()` (stop/redémarre session + engine + capture proprement).

- [ ] **Step 1:** Porter `attemptAudioReset()` de VisionClaw `AudioManager` (stop engine, `setActive(false)`, re-`setupSession()`, `startCapture()` avec le garde-fou format). Ajouter les 3 observers : `mediaServicesWereResetNotification` → `attemptAudioReset()` ; `willEnterForegroundNotification` → si `!audioEngine.isRunning` alors `attemptAudioReset()` ; dans le handler `routeChangeNotification`, cas `.oldDeviceUnavailable` → `attemptAudioReset()`. Remplacer les `try?` silencieux du bloc interruption `.ended` par un catch qui appelle `attemptAudioReset()` en dernier recours (VisionClaw `resumeAudioAfterInterruption`).
- [ ] **Step 2:** Build → SUCCEEDED. Commit `fix(one): recuperation audio (media reset / foreground / bluetooth) - regression` + push.

---

## Task 5 : UI d'appairage lunettes + état

**Pourquoi :** review major GAP-18. `OneWearablesController.connectGlasses()/disconnectGlasses()` ne sont appelés par aucune vue → `registrationState` jamais `.registered` → `OneVideoController` échoue toujours, vidéo inatteignable.

**Files:** Modify `HermesMobile/Features/One/OneWearablesController.swift` (exposer un état observable), `HermesMobile/Features/Settings/SettingsView.swift` (section One).

**Interfaces:** `OneWearablesController` expose `var registrationState` (observable/@Published) + `connectGlasses()`/`disconnectGlasses()` publics ; un accès partagé (le `OneSessionController` de Task 2 peut le posséder, ou un singleton).

- [ ] **Step 1:** S'assurer que `OneWearablesController` publie `registrationState` (mappé du `registrationStateStream` DAT) et que l'objet est accessible depuis Settings (via le controller app-level ou un singleton `OneWearablesController.shared`).
- [ ] **Step 2:** Dans la `SettingsCard("One")` : une ligne « Lunettes » avec l'état (`Connectées` / `Non connectées` / `Connexion…`) + bouton bascule `Connecter`/`Déconnecter` appelant `connectGlasses()`/`disconnectGlasses()`. Référence VisionClaw : `Views/HomeScreenView.swift` (connectGlasses) + `NonStreamView` (état device).
- [ ] **Step 3:** Build → SUCCEEDED. Commit `feat(one): appairage lunettes (bouton + etat) dans les Reglages` + push.

---

## Task 6 : Veille auto (timer) + retour-veille après délégation

**Pourquoi :** review major GAP-05. Le stepper « Veille auto 30-600s » (`OneSettings.autoStandbySeconds`) n'est lu nulle part = réglage fantôme. Et `onToolCall` ne pose pas `sleepAfterTurn` (VisionClaw le faisait) → pas de retour-veille après délégation Hermes.

**Files:** Modify `HermesMobile/Features/One/OneVoiceSessionViewModel.swift`.

**Interfaces:** Produces timer d'inactivité lisant `OneSettings.autoStandbySeconds`.

- [ ] **Step 1:** Ajouter `private var inactivityTimer: Timer?` + `armInactivityTimer()` (réf VisionClaw `armActiveInactivityTimer`) : après `autoStandbySeconds` sans activité → `stop()` (ferme la session/overlay). Réarmer sur chaque `onInputTranscription`/`onTurnComplete`. Invalider dans `stop()`.
- [ ] **Step 2:** Dans `onToolCall` (délégation Hermes), poser `sleepAfterTurn = true` (comme VisionClaw `GeminiSessionViewModel` ~l.216) pour que `onTurnComplete` retourne en veille après l'ack.
- [ ] **Step 3:** Build → SUCCEEDED. Commit `feat(one): veille auto (timer inactivite reglable) + retour-veille apres delegation` + push.

---

## Task 7 : Réveil externe (widget / Control Center / App Intent)

**Pourquoi :** review major GAP-14. Seul point d'entrée = le bouton du chat. hermex a déjà l'infra (widget target `HermesLiveActivityWidget`, `AppIntents/HermexAppIntents.swift`, App Group). VisionClaw avait `HermesActivationIntent` + `WakeSignal` branchés sur un widget.

**Files:** Modify/Create dans `HermesMobile/AppIntents/` + `HermesLiveActivityWidget/`, Modify `HermesMobile/ContentView.swift` (deep link / flag → présenter One via le `OneSessionController`).

- [ ] **Step 1:** Créer un `AppIntent` « Parler à One » (`openAppWhenRun = true`) qui pose un flag/déclenche l'ouverture de l'overlay One via le `OneSessionController` (au retour au premier plan, comme VisionClaw `WakeSignal.consume()`). Réutiliser l'App Group hermex existant.
- [ ] **Step 2:** Ajouter un contrôle Centre de contrôle (iOS 18, `ControlWidget`) et/ou un widget écran-verrouillé dans `HermesLiveActivityWidget` déclenchant cet intent. Référence VisionClaw : `HermesWidget/HermesControl.swift` + `HermesLockWidget.swift`.
- [ ] **Step 3:** `ContentView` consomme le flag au premier plan → `controller.present()`. Anti-rebond 1s (VisionClaw).
- [ ] **Step 4:** Build → SUCCEEDED (schéma app ; le widget se construit avec). Commit `feat(one): reveil externe One (App Intent + Centre de controle/widget)` + push.

---

## Task 8 : Mineurs (batch)

**Files:** Modify `HermesMobile/Resources/Info.plist`, `HermesMobile/Features/One/OneSettings.swift`, `HermesMobile/Features/Settings/SettingsView.swift`, `HermesMobile/Features/One/OneVideoController.swift`.

- [ ] **Step 1: Micro Info.plist** — `NSMicrophoneUsageDescription` mentionne les conversations vocales One (pas seulement la dictée). (Review GAP-08, risque App Review.)
- [ ] **Step 2: Reset One** — `OneSettings.resetOneDefaults()` (efface clés One + gateway Keychain) + bouton « Réinitialiser One » dans la section Réglages (réf VisionClaw `resetAll()`).
- [ ] **Step 3: Toggle vidéo à chaud** — `OneVideoController`/ViewModel : réévaluer `videoStreamingEnabled` par frame (ou stop/start à la volée) au lieu d'une seule fois au démarrage.
- [ ] **Step 4: ATS** — vérifier que `gatewayHost` par défaut (`http://...local` mDNS/LAN) fonctionne avec l'exception ATS actuelle (restreinte à `100.64.0.0/10`) ; si LAN non-Tailscale visé, élargir l'exception ou documenter le choix Tailscale-only.
- [ ] **Step 5 (optionnel, différable) : décodage vidéo arrière-plan** — porter `VideoDecoder`/VTDecompressionSession (VisionClaw `StreamSessionViewModel` ~l.174-205) pour que la vidéo continue téléphone en poche ; sinon garder la note explicite. **Décidé à l'exécution selon le temps.**
- [ ] **Step 6 (optionnel, différable) : mode caméra iPhone de test** — porter le fallback AVFoundation pour tester le pipeline vision sans lunettes. Différable.
- [ ] **Step 7:** Build → SUCCEEDED après chaque sous-étape committable. Commits séparés `chore(one): ...` + push.

---

## Self-Review

**Couverture des findings review :**
- Gateway config runtime (adversarial HIGH, Fable major) → Task 1. ✓
- Push proactif mort (Fable major) → Task 2. ✓
- Anti-écho (adversarial HIGH) → Task 3. ✓
- Récup audio (adversarial HIGH) → Task 4. ✓
- Appairage lunettes (Fable major GAP-18) → Task 5. ✓
- Veille auto fantôme + retour-veille (Fable major GAP-05) → Task 6. ✓
- Réveil externe (Fable major GAP-14, adversarial medium) → Task 7. ✓
- Micro Info.plist, Reset, toggle vidéo, ATS, décodage fond, caméra iPhone (mineurs) → Task 8. ✓
- Exclusions sanctionnées (tap média, wake word) → NON réintroduites (confirmé sans régression par les 2 reviews). ✓

**Non couvert volontairement :** capture photo lunettes (GAP-20, faible valeur pour un assistant vocal) — à décider plus tard.

**Risques :** Task 2 (remontée app-level) est la plus structurante et touche `HermesMobileApp`/`ContentView`/`ChatView` — la faire proprement avant Task 6/7 qui en dépendent. Tout est build-vérifié mais non runtime-testé sans device/mini (critère = fidélité vs VisionClaw + build vert).

## Execution Handoff (vague 2, ultracode)

Workflow ultracode recommandé : pipeline séquentiel des tâches (1→8) car elles mutent le même projet + build entre chaque ; Task 2 avant 6/7. Phase de review finale (Fable + adversarial) rejouée pour confirmer que les findings de la vague 1 sont bien fermés. Chaque tâche : build-vérifiée + commit + push, revert propre si échec.
