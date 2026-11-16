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

    /// One accessibility snapshot instead of a query per element (reading 60 buttons one by one took > 1 min,
    /// long enough for the SAS verification to time out).
    private func dumpButtons(_ tag: String) {
        guard let root = try? app.snapshot() else { return }
        var out: [String] = []
        func walk(_ s: XCUIElementSnapshot) {
            if s.elementType == .button || s.elementType == .switch, out.count < 80 { out.append("\(s.identifier)|\(s.label)") }
            for c in s.children { walk(c) }
        }
        walk(root)
        print("PSST-DIAG|\(tag)|" + out.joined(separator: " ; "))
    }

    /// Labels of all elements with the given identifier and their descendants, in order, without duplicates.
    private func labels(withIdentifier identifier: String) -> [String] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [String] = []
        func collect(_ s: XCUIElementSnapshot) {
            // the first labelled element per branch is one emoji; no de-duplication (SAS may repeat an emoji)
            if !s.label.isEmpty { out.append(s.label); return }
            for c in s.children { collect(c) }
        }
        func walk(_ s: XCUIElementSnapshot) {
            if s.identifier == identifier { collect(s); return }
            for c in s.children { walk(c) }
        }
        walk(root)
        return out
    }

    /// Taps the first hittable button whose label (or identifier) contains one of the fragments.
    @discardableResult
    private func tapContaining(_ fragments: [String], timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for f in fragments {
                let b = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR identifier CONTAINS %@", f, f)).allElementsBoundByIndex.first { $0.exists && $0.isHittable }
                if let b { b.tap(); return true }
            }
            usleep(400_000)
        } while Date() < deadline
        return false
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

    /// Puts exactly `text` into a web form field: cursor to the end, delete everything, type, check the value.
    private func setField(_ field: XCUIElement, _ text: String, secure: Bool) {
        for _ in 0..<3 {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { field.tap() }
            let current = (field.value as? String) ?? ""
            let placeholderLike = current == "Username" || current == "Password"
            let count = placeholderLike ? 0 : current.count
            if count > 0 { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count + 2)) }
            field.typeText(text)
            let value = (field.value as? String) ?? ""
            if secure ? value.count == text.count : value == text { return }
        }
    }

    override func setUp() async throws {
        continueAfterFailure = true
        app = Application.launch()
    }

    // MARK: - flow

    func testPsstAudit() {
        login()
        notificationsAndCalls()
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
        let pw = safari.secureTextFields["Password"].firstMatch
        for attempt in 1...3 {
            setField(user, app.username, secure: false)
            _ = tapAny(["Done"], in: safari, timeout: 2) // keyboard away so the password field is hittable (as upstream)
            setField(pw, app.password, secure: true)
            _ = tapAny(["Done"], in: safari, timeout: 2)
            let typedUser = (user.value as? String) ?? ""
            print("PSST-DIAG|login-fields|attempt \(attempt)|user ok: \(typedUser == app.username)|pw length ok: \(((pw.value as? String) ?? "").count == app.password.count)")
            _ = tapAny(["Continue"], in: safari, timeout: 5)
            sleep(3)
            _ = tapAny(["Not Now"], timeout: 2) || tapAny(["Not Now"], in: springboard, timeout: 2) || tapAny(["Not Now"], in: safari, timeout: 2)
            let invalid = safari.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'invalid'")).firstMatch
            if !(invalid.exists && user.exists) { break }
            print("PSST-DIAG|login-invalid|attempt \(attempt)|\(invalid.label)")
        }
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
    private var checkedOncePerVersion = false

    private func relaunchToHome() {
        app.terminate()
        app = Application.launch()
        _ = app.buttons[A11yIdentifiers.homeScreen.userAvatar].waitForExistence(timeout: 120)
        allowSystemAlerts()
        if !checkedOncePerVersion {
            checkedOncePerVersion = true
            let again = psstSwitch("notifications").waitForExistence(timeout: 8)
            print("PSST-AUDIT|notif_settings_once|\(again ? "fail" : "ok")|po reštarte tej istej verzie sa obrazovka \(again ? "znova otvorila" : "už neotvorila (raz za verziu)")")
            if again { _ = tapAny(["psst_nc-done"], timeout: 3) }
        }
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
            sleep(1)
            dumpButtons("action-menu")
            let ok = tapContaining(["👍", "thumbsup", "Thumbs up", "React"], timeout: 5)
            if !ok { _ = tapAny(["Close", "Cancel"], timeout: 2) }
            record("reaction", ok, ok ? "rýchla reakcia 👍 (doručenie overí partner)" : "reakcia v menu chýba")
        }

        // edit: our own message, no ping (so the newest item is ours, not the partner's pong)
        send("na upravu \(id)")
        if texts("na upravu \(id)").firstMatch.waitForExistence(timeout: 30), longPress("na upravu \(id)") {
            let editButton = app.buttons[A11yIdentifiers.roomScreen.timelineItemActionMenuAction.edit].firstMatch
            var ok = editButton.waitForExistence(timeout: 5)
            if ok {
                editButton.tap()
                // edit mode focuses the composer with the cursor at the end of the old text
                if app.keyboards.firstMatch.waitForExistence(timeout: 6) { app.typeText(" EDITED") } else { ok = typeInComposer(" EDITED") }
                let sendButton = app.buttons[A11yIdentifiers.roomScreen.sendButton].firstMatch
                if sendButton.waitForExistence(timeout: 3) { sendButton.tap() } else { _ = tapContaining(["Save", "Send"], timeout: 3) }
            } else {
                dumpButtons("edit-menu")
                _ = tapAny(["Close", "Cancel"], timeout: 2)
            }
            let shown = texts("EDITED").firstMatch.waitForExistence(timeout: 30)
            record("edit", ok && shown, ok ? "vlastná správa → Edit → „… EDITED“ \(shown ? "zobrazená" : "sa nezobrazila") (doručenie m.replace overí partner)" : "v menu vlastnej správy chýba Edit")
        } else { record("edit", false, "správa na úpravu sa nenašla") }

        // delete
        send("na zmazanie \(id)")
        sleep(3)
        if longPress("na zmazanie") {
            sleep(1)
            dumpButtons("delete-menu")
            if !tapContaining(["Remove", "Delete"], timeout: 3) { app.swipeUp(); _ = tapContaining(["Remove", "Delete"], timeout: 3) }
            sleep(1)
            dumpButtons("delete-confirm")
            let ok = tapContaining(["Remove", "Delete", "OK"], timeout: 5)
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
        if !tapAny([A11yIdentifiers.roomScreen.name], timeout: 5) { _ = tapContaining(["QA ios b"], timeout: 5) }
        sleep(2)
        dumpButtons("room-details")
        // DM details: "Block user" is a row further down (no People list in a DM)
        let blockButton = app.buttons["Block user"].firstMatch
        for _ in 0..<5 where !(blockButton.exists && blockButton.isHittable) { app.swipeUp(); sleep(1) }
        if blockButton.exists, blockButton.isHittable {
            blockButton.tap()
            _ = tapAny(["Block"], timeout: 8) // confirmation alert
            let unblock = app.buttons["Unblock user"].firstMatch
            let blocked = unblock.waitForExistence(timeout: 40)
            record("block", blocked, blocked ? "detail DM → Block user → potvrdenie → riadok sa zmenil na „Unblock user“ (ignore uložené na serveri)" : "po potvrdení sa „Unblock user“ neobjavilo")
            if blocked {
                unblock.tap()
                _ = tapAny(["Unblock"], timeout: 8)
                _ = app.buttons["Block user"].firstMatch.waitForExistence(timeout: 40)
            }
        } else {
            dumpButtons("room-details")
            record("block", false, "v detaile DM sa „Block user“ nenašlo")
        }
        relaunchToHome()
        if openDirectChat() { send("VERIFY-NOW \(id)") }
        relaunchToHome()
    }

    private func verification() {
        // The partner signs this account in on a new web session which asks this (verified) device to verify it.
        let accept = app.buttons[A11yIdentifiers.sessionVerificationScreen.acceptVerificationRequest].firstMatch
        guard accept.waitForExistence(timeout: 240) else {
            dumpButtons("verify-request")
            record("verify_emoji", false, "žiadosť o overenie z nového zariadenia (web) neprišla")
            return
        }
        accept.tap()
        // SAS is cancelled after 60 s without an event: tap "They match" right away, diagnostics only afterwards.
        let match = app.buttons[A11yIdentifiers.sessionVerificationScreen.acceptChallenge].firstMatch
        guard match.waitForExistence(timeout: 90) else {
            dumpButtons("verify-no-emoji")
            record("verify_emoji", false, "po prijatí žiadosti sa emoji nezobrazili")
            return
        }
        let emoji = labels(withIdentifier: A11yIdentifiers.sessionVerificationScreen.emojiWrapper)
        record("verify_emoji_ios", emoji.count == 7 ? true : nil, emoji.joined(separator: " "))
        match.tap()
        let complete = app.descendants(matching: .any)[A11yIdentifiers.sessionVerificationScreen.verificationComplete].firstMatch
        let done = complete.waitForExistence(timeout: 60)
        dumpButtons("verify-done")
        record("verify_emoji", done && emoji.count == 7,
               "iOS (overené zariadenie) prijal žiadosť nového webového prihlásenia, emoji \(emoji.joined(separator: " ")), „They match“ → \(done ? "Device verified" : "nedokončené")")
        _ = tapAny(["Done", "Continue", "Close"], timeout: 5)
    }

    // MARK: - Notifications & calls (PSST screen)

    private func psstSwitch(_ item: String) -> XCUIElement {
        app.switches["psst_nc-row-\(item)"].firstMatch
    }

    private func isOn(_ item: String) -> Bool {
        let s = psstSwitch(item)
        return s.exists && (s.value as? String) == "1"
    }

    private func rowStates() -> String {
        ["notifications", "sound", "lock_screen", "banners", "callkit", "microphone", "camera"].map { item -> String in
            let s = psstSwitch(item)
            if !s.exists { app.swipeUp() }
            return "\(item)=\(isOn(item) ? "on" : "off") (\(s.exists ? s.label : "—"))"
        }.joined(separator: "; ")
    }

    private func toggleOn(_ item: String) {
        let s = psstSwitch(item)
        for _ in 0..<3 where !(s.exists && s.isHittable) { app.swipeUp() }
        guard s.exists, !isOn(item) else { return }
        let inner = s.switches.firstMatch
        if inner.exists, inner.isHittable { inner.tap() } else { s.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
    }

    /// Taps "Allow" on every system permission alert that shows up during `seconds`.
    private func allowAlerts(for seconds: Int) -> Int {
        var count = 0
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if tapAny(["Allow", "OK", "Allow While Using App"], in: springboard, timeout: 1) { count += 1 }
        }
        return count
    }

    private func notificationsAndCalls() {
        // After login the screen opens by itself (first launch of this version) when something required is missing.
        let notifications = psstSwitch("notifications")
        let autoOpened = notifications.waitForExistence(timeout: 30)
        let banner = app.descendants(matching: .any)["psst_nc-missing_banner"].firstMatch
        let bannerText = banner.exists ? banner.label : ""
        if !autoOpened {
            let avatar = app.buttons[A11yIdentifiers.homeScreen.userAvatar].firstMatch
            if avatar.waitForExistence(timeout: 10) { avatar.tap() }
            let row = app.buttons["settings-psst_notifications_calls"].firstMatch
            if row.waitForExistence(timeout: 10) { row.tap() }
        }
        guard notifications.waitForExistence(timeout: 15) else {
            record("notif_settings", false, "obrazovka Upozornenia a hovory sa neotvorila ani automaticky, ani z Nastavení")
            return
        }
        let before = rowStates()
        print("PSST-DIAG|nc-before|\(before)")
        // several at once, one after another: "Turn on everything needed" asks for notifications, then the microphone
        var alerts = 0
        let all = app.buttons["psst_nc-request_all"].firstMatch
        for _ in 0..<3 where !(all.exists && all.isHittable) { app.swipeUp() }
        if all.exists, all.isHittable {
            all.tap()
            alerts = allowAlerts(for: 20)
        }
        app.swipeDown()
        // camera (not required) through its own toggle
        toggleOn("camera")
        alerts += allowAlerts(for: 8)
        sleep(2)
        let after = rowStates()
        print("PSST-DIAG|nc-after|\(after)")
        let required = ["notifications", "sound", "lock_screen", "banners", "microphone"]
        let requiredOn = required.allSatisfy { isOn($0) }
        record("notif_settings", autoOpened && !bannerText.isEmpty && requiredOn,
               "automaticky otvorená po prihlásení: \(autoOpened) (\(bannerText)); pred: \(before); „Zapnúť všetko potrebné“ + Kamera → \(alerts) systémových výziev povolených; po: \(after)")

        // background → foreground: the state is read again and stays consistent
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        let still = psstSwitch("notifications").waitForExistence(timeout: 10) && isOn("notifications") && isOn("microphone")
        print("PSST-DIAG|nc-foreground|\(still)|\(rowStates())")

        // test notification: same category and sound as a message, shown as a banner while the app is open
        let testNotification = app.buttons["psst_nc-test_notification"].firstMatch
        for _ in 0..<3 where !(testNotification.exists && testNotification.isHittable) { app.swipeUp() }
        if testNotification.exists {
            testNotification.tap()
            let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Test notification' OR label CONTAINS 'Testovacie upozornenie'")).firstMatch
            let shown = banner.waitForExistence(timeout: 20)
            let status = app.descendants(matching: .any)["psst_nc-status"].firstMatch
            record("notif_local_test", shown, "„Send a test notification“ → \(shown ? "banner sa zobrazil (\(banner.label.prefix(80)))" : "banner sa nezobrazil") — \(status.exists ? status.label : "")")
            sleep(6) // let the banner go away
        } else { record("notif_local_test", false, "tlačidlo testovacieho upozornenia chýba") }

        // ringing test: CallKit incoming test call for ~5 s (or the in-app sound when CallKit refuses)
        let ring = app.buttons["psst_nc-test_ringtone"].firstMatch
        for _ in 0..<3 where !(ring.exists && ring.isHittable) { app.swipeUp() }
        if ring.exists {
            ring.tap()
            let callUI = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'ringing test'")).firstMatch
            let callShown = callUI.waitForExistence(timeout: 8)
            sleep(8)
            let status = app.descendants(matching: .any)["psst_nc-status"].firstMatch
            let text = status.exists ? status.label : ""
            let callKitOK = text.contains("finished") || text.contains("skončil")
            record("ring_test", callKitOK ? true : (text.isEmpty ? false : nil),
                   "„Test ringing“ → systémové UI hovoru \(callShown ? "zobrazené" : "nevidno") — \(text)")
        } else { record("ring_test", false, "tlačidlo testu zvonenia chýba") }
        _ = tapAny(["Decline", "End"], in: springboard, timeout: 2)

        // close: Done closes the whole sheet when it was opened automatically
        if !tapAny(["psst_nc-done"], timeout: 3) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = tapAny([A11yIdentifiers.settingsScreen.done, "Close", "Done"], timeout: 3)
        }
        _ = app.buttons[A11yIdentifiers.homeScreen.startChat].waitForExistence(timeout: 10)
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
