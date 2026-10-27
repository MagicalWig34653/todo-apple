# TestFlight-Vorbereitung (iOS)

Stand 27.10.2026. Dieses Repository bereitet den Build vor; es wird nichts hochgeladen.

## Was im Repo vorbereitet ist
- `App/Config/Base.xcconfig`: `TODO_BUNDLE_ID_PREFIX` (Platzhalter `example.todo`), `DEVELOPMENT_TEAM` (leer), `MARKETING_VERSION` 0.1.0, `CURRENT_PROJECT_VERSION` 1. Lokale Werte in `App/Config/Signing.local.xcconfig` (gitignored, Vorlage: `Signing.local.xcconfig.example`).
- Bundle-IDs: `<Prefix>.ios`, `.mac`, `.watch` (project.yml).
- `App/Shared/PrivacyInfo.xcprivacy`: kein Tracking, keine gesammelten Datentypen deklariert, Required-Reason-API UserDefaults (CA92.1, Server-Adresse). Vor Release gegen tatsaechliche Datennutzung (Server-Konto, Aufgabeninhalte) in App Store Connect "App-Datenschutz" abgleichen.
- Exportcompliance: `ITSAppUsesNonExemptEncryption = NO` (nur Standard-HTTPS/System-Kryptografie). Bei Aenderung (eigene Kryptografie) neu bewerten.
- Info.plist-Texte (deutsch): `NSFaceIDUsageDescription`, `NSLocalNetworkUsageDescription`. Kamera/Fotos/Mikrofon werden noch nicht genutzt, daher keine Texte; beim Screenshot-Upload ergaenzen.
- `ExportOptions.plist`: Methode `app-store-connect`, Team-ID als Platzhalter `TEAM_ID_PLACEHOLDER` (das Skript setzt sie aus `TODO_TEAM_ID`).
- `scripts/testflight-archive.sh`: xcodegen, `xcodebuild archive`, `-exportArchive`. Umgebung: `TODO_TEAM_ID` (Pflicht), optional `TODO_BUNDLE_PREFIX`, `TODO_BUILD_NUMBER`, `TODO_VERSION`, `TODO_OUT_DIR`. `TODO_UNSIGNED=1` archiviert nur unsigniert (Pruefung).
- App-Icon: `project.yml` bindet `App/Icon` optional ein; das Skript setzt `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`, wenn `App/Icon/AppIcon.icon` (Icon Composer) existiert. Stand beim Erstellen: Ordner fehlte, Archiv ohne Icon (App Store Connect lehnt das ab). Pruefen, ob XcodeGen die `.icon`-Datei als Ressource aufnimmt.

## Associated Domains / Passkeys (Platzhalter, noch nicht aktiv)
`App/Config/Todo.entitlements.example` enthaelt `webcredentials:todo.example.invalid`. Aktivieren: kopieren nach `App/Config/Todo.entitlements`, Domain = RP-ID des Servers eintragen, in `project.yml` beim Target `Todo-iOS` `CODE_SIGN_ENTITLEMENTS` setzen. Bewusst nicht eingebunden, weil eine nicht registrierte Domain das signierte Provisioning bricht.

## Pruefung (27.10.2026)
`TODO_UNSIGNED=1 TODO_OUT_DIR=/private/tmp/claude-501/tfout scripts/testflight-archive.sh`: ARCHIVE SUCCEEDED (generic iOS, CODE_SIGNING_ALLOWED=NO). Im Archiv: Bundle-ID `example.todo.ios`, 0.1.0 (1), Encryption false, Usage-Texte und `PrivacyInfo.xcprivacy` vorhanden. Signierter Export und Upload nicht geprueft (keine Team-ID).

## Manuell durch den Nutzer
1. Apple Developer Program: Team-ID ermitteln (developer.apple.com, Membership); in `Signing.local.xcconfig` und als `TODO_TEAM_ID` setzen.
2. Eigene Bundle-ID waehlen (Prefix), im Developer-Portal App-ID `<Prefix>.ios` mit Capability "Associated Domains" anlegen.
3. App Store Connect: App-Eintrag mit dieser Bundle-ID anlegen; Datenschutz-Angaben und Exportcompliance beantworten; interne Tester einladen.
4. Domain + Passkeys: Domain/RP-ID festlegen (HTTPS), `https://<domain>/.well-known/apple-app-site-association` ausliefern, JSON ohne Dateiendung, `Content-Type: application/json`, Inhalt `{"webcredentials":{"apps":["<TEAMID>.<Prefix>.ios"]}}`; Entitlement aktivieren (siehe oben). Server muss HTTPS bieten (der lokale `NSAllowsLocalNetworking`-Ausnahmepfad reicht fuer TestFlight nicht fuer entfernte Server).
5. Build: `TODO_TEAM_ID=... TODO_BUILD_NUMBER=<fortlaufend> scripts/testflight-archive.sh`. Jede Uploadrunde braucht eine neue Build-Nummer.
6. Upload (manuell): Transporter.app mit der IPA aus `build/testflight/export`, oder `xcrun altool --upload-app -f <ipa> -t ios --apiKey <KEY> --apiIssuer <ISSUER>` (API-Key aus App Store Connect; nicht ins Repo). `notarytool` ist nur fuer macOS-Notarisierung, nicht fuer TestFlight.
7. Nach der Verarbeitung Build in TestFlight dem Testteam zuweisen.
