# TestFlight-Vorbereitung (iOS)

Stand 27.10.2026. Dieses Repository bereitet den Build vor; Upload nur mit `TODO_UPLOAD=1`.

## Was im Repo vorbereitet ist
- `App/Config/Base.xcconfig`: `TODO_BUNDLE_ID_PREFIX` (`de.linolaske.todo`), `DEVELOPMENT_TEAM` (leer), `MARKETING_VERSION` 0.1.0, `CURRENT_PROJECT_VERSION` 1. Lokale Werte in `App/Config/Signing.local.xcconfig` (gitignored, Vorlage: `Signing.local.xcconfig.example`).
- Bundle-IDs: iOS = `<Prefix>` selbst (`de.linolaske.todo`), macOS `<Prefix>.mac`, watchOS `<Prefix>.watch` (project.yml). Team-ID `J2DU2P47XW` nur in der gitignorierten `Signing.local.xcconfig`.
- `App/Shared/PrivacyInfo.xcprivacy`: kein Tracking, keine gesammelten Datentypen deklariert, Required-Reason-API UserDefaults (CA92.1, Server-Adresse). Vor Release gegen tatsaechliche Datennutzung (Server-Konto, Aufgabeninhalte) in App Store Connect "App-Datenschutz" abgleichen.
- Exportcompliance: `ITSAppUsesNonExemptEncryption = NO` (nur Standard-HTTPS/System-Kryptografie). Bei Aenderung (eigene Kryptografie) neu bewerten.
- Info.plist-Texte (deutsch): `NSFaceIDUsageDescription`, `NSLocalNetworkUsageDescription`. Kamera/Fotos/Mikrofon werden noch nicht genutzt, daher keine Texte; beim Screenshot-Upload ergaenzen.
- `ExportOptions.plist`: Methode `app-store-connect`, Team-ID als Platzhalter `TEAM_ID_PLACEHOLDER` (das Skript setzt sie aus `TODO_TEAM_ID`).
- `scripts/testflight-archive.sh`: xcodegen, `xcodebuild archive`, `-exportArchive`. Umgebung: `TODO_TEAM_ID` (Pflicht), optional `TODO_BUNDLE_PREFIX`, `TODO_BUILD_NUMBER`, `TODO_VERSION`, `TODO_OUT_DIR`. `TODO_UNSIGNED=1` archiviert nur unsigniert (Pruefung).
- App-Icon: `project.yml` bindet `App/Icon` optional ein; das Skript setzt `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`, wenn `App/Icon/AppIcon.icon` (Icon Composer) existiert. Stand beim Erstellen: Ordner fehlte, Archiv ohne Icon (App Store Connect lehnt das ab). Pruefen, ob XcodeGen die `.icon`-Datei als Ressource aufnimmt.

## Associated Domains / Passkeys (aktiv)
`App/Config/Todo.entitlements` (`webcredentials:todo.linolaske.de`) ist ueber `CODE_SIGN_ENTITLEMENTS` in `project.yml` fuer Todo-iOS und Todo-macOS eingebunden. Die RP-ID/Passkey-Domain ist `todo.linolaske.de`.

### apple-app-site-association (AASA)
Fertige Datei: `docs/aasa/apple-app-site-association` (Team `J2DU2P47XW`, appID `J2DU2P47XW.de.linolaske.todo` (iOS+macOS, Universal Purchase)). Auf `todo.linolaske.de` ausliefern unter `https://todo.linolaske.de/.well-known/apple-app-site-association`: HTTPS mit gueltigem Zertifikat, ohne Dateiendung, `Content-Type: application/json`, kein Redirect, oeffentlich erreichbar. Apple holt die Datei ueber sein CDN (Aenderungen brauchen u. U. Stunden/Tage; fuer Entwicklung `?mode=developer` bei Entwicklungs-Signierung mit `webcredentials:todo.linolaske.de?mode=developer`). Status: Datei liegt im Repo, auf dem Server noch NICHT ausgeliefert/geprueft.

## Pruefung (27.10.2026)
`TODO_UNSIGNED=1 TODO_OUT_DIR=/private/tmp/claude-501/tfout scripts/testflight-archive.sh`: ARCHIVE SUCCEEDED (generic iOS, CODE_SIGNING_ALLOWED=NO). Im Archiv: Bundle-ID `example.todo.ios` (damals Platzhalter), 0.1.0 (1), Encryption false, Usage-Texte und `PrivacyInfo.xcprivacy` vorhanden. Signierter Export und Upload nicht geprueft (keine Team-ID).

## Signierter Lauf (27.10.2026, Team J2DU2P47XW)
`TODO_TEAM_ID=J2DU2P47XW scripts/testflight-archive.sh` mit `-allowProvisioningUpdates` (Xcode-Konto):
- App-ID `de.linolaske.todo` wurde automatisch angelegt (Profil "iOS Team Provisioning Profile: de.linolaske.todo" in `~/Library/Developer/Xcode/UserData/Provisioning Profiles`; Entitlement Associated Domains im Profil). Archiv: ARCHIVE SUCCEEDED, Entwicklungs-Signatur (Apple Development).
- Export `app-store-connect`: EXPORT SUCCEEDED. IPA signiert mit "Apple Distribution: Lino Laske (J2DU2P47XW)" (Cloud-managed, von Xcode automatisch erzeugt), Profil "iOS Team Store Provisioning Profile: de.linolaske.todo", `get-task-allow=false`, `webcredentials:todo.linolaske.de` in den Entitlements, Version 0.1.0 (1). Es fehlt also kein Distribution-Zertifikat.
- Nichts hochgeladen. App-Store-Connect-Eintrag existiert noch nicht (Nutzer legt ihn an, Bundle-ID `de.linolaske.todo`).
- Stolperstein: Mit Standard-Ausgabe `build/testflight` im Ordner "Documents" scheitert CodeSign ("resource fork, Finder information, or similar detritus not allowed", iCloud/File-Provider-Attribute). Loesung: `TODO_OUT_DIR` ausserhalb von Documents setzen, z. B. `TODO_OUT_DIR=/private/tmp/tfout`.
- Der Skriptlauf dauert (Icon-Compile) ueber 2 Minuten.

## Manuell durch den Nutzer
1. Erledigt: Team-ID `J2DU2P47XW` in `Signing.local.xcconfig` (lokal) und als `TODO_TEAM_ID`.
2. Erledigt: App-ID `de.linolaske.todo` angelegt (siehe oben). Im Developer-Portal pruefen, dass Capability "Associated Domains" an der App-ID aktiv ist.
3. App Store Connect: App-Eintrag mit dieser Bundle-ID anlegen; Datenschutz-Angaben und Exportcompliance beantworten; interne Tester einladen.
4. Domain + Passkeys: Domain/RP-ID festlegen (HTTPS), `https://<domain>/.well-known/apple-app-site-association` ausliefern, JSON ohne Dateiendung, `Content-Type: application/json`, Inhalt siehe `docs/aasa/apple-app-site-association`; Entitlement aktivieren (siehe oben). Server muss HTTPS bieten (der lokale `NSAllowsLocalNetworking`-Ausnahmepfad reicht fuer TestFlight nicht fuer entfernte Server).
5. Build: `TODO_TEAM_ID=... TODO_BUILD_NUMBER=<fortlaufend> scripts/testflight-archive.sh`. Jede Uploadrunde braucht eine neue Build-Nummer.
6. Upload (manuell): Transporter.app mit der IPA aus `build/testflight/export`, oder `xcrun altool --upload-app -f <ipa> -t ios --apiKey <KEY> --apiIssuer <ISSUER>` (API-Key aus App Store Connect; nicht ins Repo). `notarytool` ist nur fuer macOS-Notarisierung, nicht fuer TestFlight.
7. Nach der Verarbeitung Build in TestFlight dem Testteam zuweisen.

## Upload (27.10.2026, erfolgreich)
`TODO_TEAM_ID=J2DU2P47XW TODO_UPLOAD=1 TODO_OUT_DIR=/private/tmp/tfout TODO_BUILD_NUMBER=$(date +%y%m%d%H%M) scripts/testflight-archive.sh` setzt im Export `destination=upload` (PlistBuddy) und laedt ueber das in Xcode angemeldete Konto hoch (kein Passwort/API-Key noetig). Ergebnis: Version 0.1.0, Build 2610271206, "Upload succeeded", Delivery UUID `76573aed-cc05-4e99-bbfa-e425d8429ce4`, keine Warnungen/Fehler in den Distribution-Logs, App-Icon (Icon Composer) im Archiv. Es gibt dabei keine lokale IPA (`export/` bleibt leer).
Offen in App Store Connect: Verarbeitung abwarten (Mail/TestFlight-Tab), Build interner Testgruppe zuweisen; fuer externe Tester Beta-App-Pruefungsinfos ausfuellen. Jede weitere Runde braucht eine neue Build-Nummer (Zeitstempel reicht).

## macOS (27.10.2026)
`TODO_TEAM_ID=J2DU2P47XW TODO_ARCHIVE_ONLY=1 TODO_OUT_DIR=/private/tmp/claude-501/tfmac scripts/testflight-archive-mac.sh` archiviert `Todo-macOS` signiert (`-allowProvisioningUpdates`) und registriert dabei die App-ID `de.linolaske.todo.mac`. Ergebnis: ARCHIVE SUCCEEDED, Entitlements enthalten `webcredentials:todo.linolaske.de`, App-Sandbox, `network.client`, `files.user-selected.read-only`. Ohne `TODO_ARCHIVE_ONLY` folgt `-exportArchive` (Methode `app-store-connect`); `TODO_UPLOAD=1` laedt hoch, braucht aber einen macOS-App-Eintrag in App Store Connect (Bundle-ID `de.linolaske.todo.mac`) und wurde NICHT ausgefuehrt. Die AASA-Datei enthaelt die Mac-App-ID bereits. Fuer Mac-Distribution ausserhalb des App Store waere zusaetzlich Developer-ID-Signierung und Notarisierung noetig (nicht eingerichtet).

## Upload Steuerzentrale (30.10.2026)
iOS: Version 0.1.0, Build 2610301841, "Upload succeeded", Delivery UUID `8ce50dc8-5b74-40da-a570-cab8833dc967` (Stand 810e44d, Steuerzentrale Kanban/Liste). macOS: Archiv gebaut (Build 2610301841), Export/Upload SCHEITERT: `App record with bundle identifier "de.linolaske.todo.mac" not found on App Store Connect`. Der Nutzer muss den macOS-App-Eintrag anlegen, danach `TODO_UPLOAD=1 scripts/testflight-archive-mac.sh` erneut ausfuehren.

## Upload Recovery-Flow (30.10.2026)
iOS: Version 0.1.0, Build 2610302241, "Upload succeeded", Delivery UUID `f1f92ba9-5146-4e27-85a6-3a7a002692ef` (Stand e0a2018: Recovery-Anmeldung, Passkey-Fehlertexte, Steuerzentrale, Server-State). macOS nicht hochgeladen (App-Eintrag `de.linolaske.todo.mac` fehlt). Verarbeitung in App Store Connect nicht geprueft.

## Checkpoint: macOS Universal Purchase (2026-10-30)
macOS nutzt jetzt die Bundle-ID `de.linolaske.todo` (wie iOS, ein App-Store-Connect-Eintrag). macOS-Build 2610302313 (Version 0.1.0): "Upload succeeded" (Mac App-ID/Profil "Mac Team Provisioning Profile: de.linolaske.todo" automatisch). Erster Versuch (2610302310) scheiterte an fehlendem ICNS/512@2x-Icon; behoben, indem `Todo-macOS` das `AppIcon.icon` einbindet (`ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`). Delivery UUID nicht mitgeschrieben. Verarbeitung in App Store Connect nicht geprueft. Build-Nummern je Plattform eindeutig halten. Das Backend-AASA darf die alte `.mac`-ID behalten (harmlos).

## Upload Redesign + Steuerzentrale + Recovery (2026-10-30, Universal Purchase)
Beide aus sauberem Stand (main, nach `git pull --rebase`), Bundle-ID `de.linolaske.todo`, Version 0.1.0, Inhalt: Redesign (Aufgabenzeile, Detail, Schnell-Hinzufuegen, Tabs), Steuerzentrale, Recovery-Flow, Passkey-Fehlertexte.
- iOS: Build 2610302335, "Upload succeeded", Delivery UUID `773c19b8-afb2-44d4-b13e-c0203b997aab`.
- macOS: Build 2610302340, "Upload succeeded", Delivery UUID `4c0d573d-0736-4933-9744-f9be5c0af2cc`.
- UUIDs stammen aus `$TMPDIR/*.xcdistributionlogs` (das Skript druckt sie nicht). Die Logs enthalten je eine ERROR-Zeile "Failed to create URL for CDUploaderStateInfoResumeFilePath" (Resume-Datei, Upload lief trotzdem durch).
- Nicht geprueft: Verarbeitung/Freigabe in App Store Connect, Funktion der Builds auf Geraeten.

## Produktname "Todolino" (31.10.2026)
Der sichtbare Name ist "Todolino": `CFBundleDisplayName` (iOS/macOS/watchOS) per `INFOPLIST_KEY_CFBundleDisplayName`, `CFBundleName` (Mac-Menueleiste "Todolino", "Ueber Todolino", "Todolino beenden") ueber `App/Shared/InfoPlist.xcstrings`, Face-ID-/Netzwerk-Beschreibung, Login-Wortmarke und Fenstertitel ueber den String `app.title`. Unveraendert: Bundle-IDs (`de.linolaske.todo`, `.watch`), Target-/Scheme-Namen, Archivnamen der Skripte, Domain, Schluesselbund-/UserDefaults-Schluessel.
Hinweis: Den App-Store-Connect-Namen ("Todolino" oder Alternative) legt der Nutzer beim Anlegen des App-Eintrags selbst fest; er muss nicht mit dem Anzeigenamen auf dem Geraet uebereinstimmen, ist aber in App Store Connect eindeutig zu waehlen (ggf. Namenskonflikt pruefen).

## Upload HIG, Sync-410, Todolino (2026-10-31, Universal Purchase)
Aus sauberem Stand (main, nach `git pull --rebase`, Stand 0b81ee4-Nachfolger), Bundle-ID `de.linolaske.todo`, Version 0.1.0. Inhalt: HIG-Verbesserungen (Dynamic Type AX5, Kontraste, Inspector, Menueleiste, Undo, VoiceOver), 410-`cursor_expired`-Behandlung im Sync, Todolino-Name, Recovery-Flow, Steuerzentrale (Runner nur Mac-seitige Bibliothek, kein App-Feature).
- Vorab: Todo-watchOS Build (Simulator, unsigniert) erfolgreich; TodoCore-Tests (aus `TodoCore/`): 130 Tests, 17 uebersprungen, 0 Fehler.
- iOS: Build 2610310643, "Upload succeeded", Delivery UUID `e3180b33-e969-4948-a445-0dece42d0b4f`.
- macOS: Build 2610310645, "Upload succeeded", Delivery UUID `92716b88-96b1-4d98-9d06-26afa8c546d3`.
- Hinweis: `xcodebuild test -scheme TodoCore` muss im Verzeichnis `TodoCore/` laufen (im Repo-Root ist das Schema nicht fuer Tests konfiguriert).
- Nicht geprueft: Verarbeitung/Freigabe in App Store Connect, Funktion der Builds auf Geraeten.

## Upload Stand 0b81ee4 (2026-10-31, Universal Purchase)
Aus sauberem Stand (main, `git pull --rebase` ohne Aenderungen), Bundle-ID `de.linolaske.todo`, Version 0.1.0.
- Vorab: Todo-watchOS Build (unsigniert) erfolgreich; TodoCore-Tests (aus `TodoCore/`): 142 Tests, 18 uebersprungen, 0 Fehler.
- iOS: Build 2610310815, "Upload succeeded", Delivery UUID `6dec881f-608e-43a9-bf33-5b535d12d03c`.
- macOS: Build 2610310818, "Upload succeeded", Delivery UUID `902d14e2-6248-4dd4-9ed4-4d8cf8ed2db6`.
- Nicht geprueft: Verarbeitung/Freigabe in App Store Connect, Funktion der Builds auf Geraeten.

## Upload Stand d51900c (2026-10-31, Planung/Labels ueber Sync-Queue)
Aus sauberem Stand (main, `git pull --rebase` ohne Aenderungen), Version 0.1.0. Inhalt: Planung und Labels ueber die Sync-Queue (Contract 1.4.0), Detail-Audit-Fix.
- **Server mindestens sha-15b4f06 noetig** fuer Planung/Labels per Sync-Queue; aeltere Server: REST-Fallback.
- Vorab: Todo-watchOS Build (unsigniert) erfolgreich; TodoCore-Tests (aus `TodoCore/`): 159 Tests, 19 uebersprungen, 0 Fehler.
- iOS: Build 2610311104, "Upload succeeded", Delivery UUID `762ff3d6-4e2d-4d44-803f-3f50742efae9`.
- macOS: Build 2610311108, "Upload succeeded", Delivery UUID `f3b8301c-334b-4aa3-a4fa-d7825baf6a91`.
- Nicht geprueft: Verarbeitung/Freigabe in App Store Connect, Funktion der Builds auf Geraeten.

## Upload Push/Live-Refresh/Fuer-dich (2026-10-31, Stand ec3ff59, Universal Purchase)
Aus sauberem Stand (main, `git pull --rebase` ohne Aenderungen), Version 0.1.0, Push-Capability fuer `de.linolaske.todo` im Developer Portal aktiv. Inhalt: APNs-Push-Client, Live-Refresh (Long-Poll), Fuer-dich-Feed als erster Tab, Planung/Labels ueber Sync, HIG-Verbesserungen.
- **Server-Voraussetzung:** Backend mindestens Image mit `/v1/feed`, `/v1/sync/wait`, `/v1/push/*` (ab sha-02b91a4 oder neuer; Migrationen via update.sh).
- Vorab: Todo-watchOS Build (unsigniert) und Todo-iOS Simulator-Build (unsigniert) erfolgreich; TodoCore-Tests (aus `TodoCore/`): 192 Tests, 22 uebersprungen, 0 Fehler.
- iOS: Build 2610311632, "Upload succeeded", Delivery UUID `a0eb6018-3c86-4c43-ae1b-cc8e66d2a55c`.
- macOS: Build 2610311634, "Upload succeeded", Delivery UUID `0739c61e-8c12-4246-bbec-b837351f0cf9`.
- Entitlement-Befund: Archivierung lief mit automatischem Signieren ohne Capability-/Profilfehler. Im `.xcarchive` (Entwicklungs-signiert) zeigt `codesign -d --entitlements :-` erwartungsgemaess `aps-environment=development` (iOS) bzw. `com.apple.developer.aps-environment=development` (macOS). Beim Export/Upload signiert Xcode fuer Distribution neu; die xcdistributionlogs (IDEDistributionProvisioning) enthalten `aps-environment = production` fuer beide. Das fertige exportierte Binary wurde nicht separat per codesign geprueft (Export wird nur hochgeladen).
- Nicht geprueft: Verarbeitung/Freigabe in App Store Connect, Funktion der Builds und echter Push auf Geraeten.
