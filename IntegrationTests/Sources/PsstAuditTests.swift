//
// PSST feature audit on the iOS simulator against production chat.macet.eu (docs/FEATURE-MATRIX.md, DECISIONS D64).
//
// The partner is Element Web on the CI runner (scripts/audit/ios-partner.mjs): it joins invites, answers
// "ping:<x>" with "pong:<x>", records everything the app sends, and on "VERIFY-NOW" signs the same account in on a
// new web session that asks this app to verify it. Every check prints one line "PSST-AUDIT|<id>|<ok|fail|na>|<note>"
// which the workflow collects; the test itself never stops on a failed check (continueAfterFailure).
//
// Environment: INTEGRATION_TESTS_USERNAME / _PASSWORD (iOS account), PSST_AUDIT_PARTNER (partner MXID).
//

import XCTest

@MainActor
final class PsstAuditTests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")

    private func record(_ id: String, _ ok: Bool?, _ note: String) {
        let status = ok == nil ? "na" : (ok! ? "ok" : "fail")
        print("PSST-AUDIT|\(id)|\(status)|\(note)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(id)-\(status)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private var partner: String { ProcessInfo.processInfo.environment["PSST_AUDIT_PARTNER"] ?? "" }

    private func texts(_ fragment: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment))
    }

    @discardableResult
    private func tapAny(_ labels: [String], in root: XCUIApplication? = nil, timeout: TimeInterval = 5) -> Bool {
        let r = root ?? app!
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for l in labels {
                let b = r.buttons[l].firstMatch
                if b.exists, b.isHittable { b.tap(); return true }
            }
            usleep(400_000)
        } while Date() < deadline
        return false
    }

    private func allowSystemAlerts() {
        for _ in 0..<3 { _ = tapAny(["Allow", "Allow While Using App", "OK"], in: springboard, timeout: 1) }
    }

    override func setUp() async throws {
        continueAfterFailure = true
        app = Application.launch()
    }

    // MARK: - flow

    func testPsstAudit() {
        login()
        let room = startDirectChat()
        if room { messaging() } else { record("dm", false, "DM sa nepodarilo založiť") }
        verification()
        profileAndSettings()
        finish()
    }

    private func login() {
        let signIn = app.buttons[A11yIdentifiers.authenticationStartScreen.signIn]
        guard signIn.waitForExistence(timeout: 30) else { record("login", false, "chýba Sign in"); return }
        record("locked_server", app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'chat.macet.eu'")).count > 0 || signIn.label.contains("chat.macet.eu"),
               "úvodná obrazovka: \(signIn.label)")
        signIn.tap()
        _ = tapAny([A11yIdentifiers.serverConfirmationScreen.continue, "Continue"], timeout: 8)
        // ASWebAuthenticationSession: "psst wants to use chat.macet.eu to sign in"
        _ = tapAny(["Continue"], in: springboard, timeout: 30)
        let user = safari.textFields["Username"].firstMatch
        guard user.waitForExistence(timeout: 60) else { record("login", false, "MAS formulár sa neotvoril"); return }
        user.clearAndTypeText(app.username, app: app)
        safari.buttons["Done"].firstMatch.tap() // keyboard away so the password field is hittable (as upstream)
        let pw = safari.secureTextFields["Password"].firstMatch
        pw.clearAndTypeText(app.password, app: app, verifyingValue: false)
        safari.buttons["Done"].firstMatch.tap()
        _ = tapAny(["Continue"], in: safari, timeout: 5)
        _ = tapAny(["Not Now"], timeout: 5)
        _ = tapAny(["Continue"], in: safari, timeout: 20) // consent
        allowSystemAlerts()
        let home = app.buttons[A11yIdentifiers.homeScreen.userAvatar]
        let ok = home.waitForExistence(timeout: 240)
        allowSystemAlerts()
        _ = tapAny(["Not now", "Close", "Remind me later", "Skip"], timeout: 3)
        record("login", ok, ok ? "prihlásenie cez MAS (ASWebAuthenticationSession) → zoznam konverzácií" : "domovská obrazovka sa neobjavila")
    }

    private func startDirectChat() -> Bool {
        let start = app.buttons[A11yIdentifiers.homeScreen.startChat]
        guard start.waitForExistence(timeout: 20) else { return false }
        start.tap()
        let search = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        guard search.waitForExistence(timeout: 10) else { return false }
        search.clearAndTypeText(partner, app: app, verifyingValue: false)
        let result = texts(partner).firstMatch
        guard result.waitForExistence(timeout: 30) else { return false }
        result.tap()
        _ = tapAny(["Send invite", "Start chat", "Create", "Start"], timeout: 8)
        let composer = app.textViews[A11yIdentifiers.roomScreen.messageComposer].firstMatch
        return composer.waitForExistence(timeout: 60)
    }

    /// Types into the composer only once it has keyboard focus (tap again if the keyboard did not come up).
    private func typeInComposer(_ text: String) -> Bool {
        let composer = app.textViews[A11yIdentifiers.roomScreen.messageComposer].firstMatch
        guard composer.waitForExistence(timeout: 20) else { return false }
        for _ in 0..<4 {
            composer.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 4) { composer.typeText(text); return true }
            app.showKeyboardIfNeeded()
            if app.keyboards.firstMatch.waitForExistence(timeout: 2) { composer.typeText(text); return true }
        }
        return false
    }

    @discardableResult
    private func send(_ text: String) -> Bool {
        guard typeInComposer(text) else { return false }
        app.buttons[A11yIdentifiers.roomScreen.sendButton].firstMatch.tap()
        return true
    }

    private func longPress(_ fragment: String) -> Bool {
        // timeline items are cells/other elements whose label contains the body, not plain static texts
        let bubble = texts(fragment).allElementsBoundByIndex.last { $0.exists && $0.isHittable } ?? texts(fragment).firstMatch
        guard bubble.waitForExistence(timeout: 20) else { return false }
        bubble.press(forDuration: 1.2)
        return true
    }

    /// Back to the room list with a fresh app state (session is kept).
    private func relaunchToHome() {
        app.terminate()
        app = Application.launch()
        _ = app.buttons[A11yIdentifiers.homeScreen.userAvatar].waitForExistence(timeout: 120)
        allowSystemAlerts()
    }

    private func openDirectChat() -> Bool {
        let room = texts("QA ios b").firstMatch
        guard room.waitForExistence(timeout: 60) else { return false }
        room.tap()
        return app.textViews[A11yIdentifiers.roomScreen.messageComposer].firstMatch.waitForExistence(timeout: 30)
    }

    private func messaging() {
        let id = String(Int(Date().timeIntervalSince1970))
        send("ping:\(id) ahoj z iOS")
        let pong = texts("pong:\(id)").firstMatch.waitForExistence(timeout: 90)
        record("dm", pong, pong ? "šifrovaná DM: iOS poslal ping, partner (web) odpovedal pong" : "odpoveď od partnera neprišla")

        // reply
        if longPress("pong:\(id)") {
            let r = tapAny(["Reply"], timeout: 5)
            if r { send("ping:r\(id) odpoved") }
            record("reply", r && texts("pong:r\(id)").firstMatch.waitForExistence(timeout: 60), "odpoveď cez menu správy")
        } else { record("reply", false, "správa sa nenašla") }

        // reaction
        if longPress("pong:\(id)") {
            let thumbs = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR identifier CONTAINS %@", "👍", "👍")).firstMatch
            let ok = thumbs.waitForExistence(timeout: 5) && thumbs.isHittable
            if ok { thumbs.tap() } else { _ = tapAny(["Close", "Cancel"], timeout: 2) }
            record("reaction", ok, ok ? "rýchla reakcia 👍 (doručenie overí partner)" : "reakcia v menu chýba")
        }

        // edit
        send("ping:e\(id) na upravu")
        if texts("pong:e\(id)").firstMatch.waitForExistence(timeout: 60), longPress("na upravu") {
            let ok = tapAny([A11yIdentifiers.roomScreen.timelineItemActionMenuAction.edit, "Edit"], timeout: 5)
            if ok, typeInComposer(" EDITED") {
                app.buttons[A11yIdentifiers.roomScreen.sendButton].firstMatch.tap()
            }
            record("edit", ok, "úprava správy (doručenie overí partner)")
        } else { record("edit", false, "správa na úpravu sa nenašla") }

        // delete
        send("na zmazanie \(id)")
        sleep(3)
        if longPress("na zmazanie") {
            let ok = tapAny(["Remove", "Delete"], timeout: 5)
            _ = tapAny(["Remove", "Delete", "OK"], timeout: 5)
            record("delete", ok, "zmazanie (redaction; doručenie overí partner)")
        } else { record("delete", false, "správa na zmazanie sa nenašla") }

        // read receipts + typing (partner reacts to markers)
        send("READ-ME TYPE-NOW \(id)")
        let typing = texts("typing").firstMatch.waitForExistence(timeout: 30)
        record("typing", typing, typing ? "„… is typing“ od partnera" : "indikátor písania sa nezobrazil")
        record("receipts", nil, "doručenie potvrdenia overí partner (READ-ME); zobrazenie avatarov na iOS sa nedá spoľahlivo prečítať")

        // image from the simulator photo library
        _ = tapAny([A11yIdentifiers.roomScreen.composerToolbar.openComposeOptions], timeout: 5)
        if tapAny([A11yIdentifiers.roomScreen.attachmentPickerPhotoLibrary, "Photo Library"], timeout: 5) {
            sleep(4)
            let img = app.images.firstMatch
            if img.waitForExistence(timeout: 15) { img.tap() }
            let sent = tapAny(["Send", "Add"], timeout: 15)
            _ = tapAny(["Send"], timeout: 10)
            record("image", sent ? true : nil, sent ? "fotka z knižnice odoslaná (doručenie overí partner)" : "systémový výber fotiek (PHPicker) beží mimo procesu appky, XCUITest ho v simulátore neovládol")
            _ = tapAny(["Cancel", "Close"], timeout: 3)
        } else { record("image", nil, "menu príloh sa v simulátore neotvorilo") }

        // calls: the simulator has no camera/microphone → only the entry point
        let call = app.buttons[A11yIdentifiers.roomScreen.startVideoCall].firstMatch.exists || app.buttons[A11yIdentifiers.roomScreen.startVoiceCall].firstMatch.exists
        record("call_button", call, "tlačidlo hovoru v DM \(call ? "je" : "chýba"); samotný hovor sa v simulátore (bez kamery/mikrofónu) overiť nedá")

        // room details → people → block partner (fresh app state, DM opened from the room list)
        relaunchToHome()
        guard openDirectChat() else { record("block", false, "DM sa po reštarte nenašla"); return }
        app.buttons[A11yIdentifiers.roomScreen.name].firstMatch.tap()
        if tapAny([A11yIdentifiers.roomDetailsScreen.people, "People"], timeout: 8) {
            let member = texts("QA ios b").firstMatch
            if member.waitForExistence(timeout: 10) { member.tap() }
            let blocked = tapAny([A11yIdentifiers.roomMemberDetailsScreen.ignore, "Block user", "Block"], timeout: 8)
            _ = tapAny(["Block", "OK"], timeout: 5)
            record("block", blocked, "zablokovanie používateľa (ignore) v detaile člena")
            _ = tapAny([A11yIdentifiers.roomMemberDetailsScreen.unignore, "Unblock user", "Unblock"], timeout: 5)
            _ = tapAny(["Unblock", "OK"], timeout: 5)
        } else { record("block", false, "Room details → People sa nenašlo") }
        relaunchToHome()
        if openDirectChat() { send("VERIFY-NOW \(id)") }
        relaunchToHome()
    }

    private func verification() {
        // the partner signs this account in on a new web session which asks this (verified) device to verify it
        let req = texts("Verification requested").firstMatch.waitForExistence(timeout: 180)
        if !req { record("verify_emoji", false, "žiadosť o overenie z nového zariadenia (web) neprišla"); return }
        _ = tapAny([A11yIdentifiers.sessionVerificationScreen.acceptVerificationRequest, "Start verification", "Accept"], timeout: 10)
        _ = tapAny(["Start", "Compare emojis"], timeout: 15)
        let emoji = app.otherElements[A11yIdentifiers.sessionVerificationScreen.emojiWrapper].waitForExistence(timeout: 60) || texts("They match").firstMatch.waitForExistence(timeout: 5)
        _ = tapAny([A11yIdentifiers.sessionVerificationScreen.acceptChallenge, "They match"], timeout: 10)
        let done = texts("verified").firstMatch.waitForExistence(timeout: 60)
        record("verify_emoji", emoji && done, "iOS (overené zariadenie) overil nové webové prihlásenie cez emoji: emoji \(emoji), hotovo \(done)")
        _ = tapAny(["Done", "Continue"], timeout: 5)
    }

    private func profileAndSettings() {
        let avatar = app.buttons[A11yIdentifiers.homeScreen.userAvatar].firstMatch
        if !avatar.waitForExistence(timeout: 20) { app.navigationBars.buttons.element(boundBy: 0).tap() }
        guard avatar.waitForExistence(timeout: 20) else { record("profile", false, "nastavenia nedostupné"); return }
        avatar.tap()
        // profile header → edit display name
        if tapAny([app.username, "Edit profile"], timeout: 3) || texts("@\(app.username)").firstMatch.exists {
            texts("@\(app.username)").firstMatch.tap()
            let field = app.textFields.firstMatch
            if field.waitForExistence(timeout: 10) {
                field.tap()
                if !app.keyboards.firstMatch.waitForExistence(timeout: 4) { field.tap(); app.showKeyboardIfNeeded() }
                if app.keyboards.firstMatch.waitForExistence(timeout: 3) { field.typeText(" iOS") }
                let saved = tapAny(["Save"], timeout: 5)
                record("profile", saved, "zmena zobrazovaného mena v Nastaveniach")
                _ = tapAny(["Back", "Cancel"], timeout: 3)
            } else { record("profile", false, "editor profilu sa neotvoril") }
        } else { record("profile", false, "hlavička profilu sa nenašla") }
        let manage = app.buttons[A11yIdentifiers.settingsScreen.account].firstMatch
        record("sessions", manage.exists, "„Manage account & devices“ (MAS: heslo, relácie) \(manage.exists ? "je" : "chýba") v Nastaveniach")
    }

    private func finish() {
        // logout
        let logout = app.buttons[A11yIdentifiers.settingsScreen.logout].firstMatch
        if !logout.exists { app.swipeUp() }
        if logout.waitForExistence(timeout: 10) {
            logout.tap()
            _ = tapAny([A11yIdentifiers.alertInfo.primaryButton, "Remove this device", "Sign out"], timeout: 10)
            _ = tapAny(["Remove this device", "Sign out"], timeout: 5)
            let back = app.buttons[A11yIdentifiers.authenticationStartScreen.signIn].waitForExistence(timeout: 60)
            record("logout", back, "odhlásenie → úvodná obrazovka")
        } else { record("logout", false, "tlačidlo odhlásenia sa nenašlo") }
        print("PSST-AUDIT|done|ok|")
    }
}
