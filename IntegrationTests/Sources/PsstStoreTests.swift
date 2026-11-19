//
// PSST (D87): App Store material and review checks on the iOS simulator against production psst.pro.
//
//   testStoreScreenshots  signs in an account whose chats were prepared from Element Web (fictional people),
//                         confirms the identity with the recovery key (PSST_RECOVERY_KEY) so the encrypted history
//                         is readable, and saves full-screen PNGs (native resolution, status bar overridden by the
//                         workflow) to PSST_SHOT_DIR: 1-chats, 2-group, 3-chat, 4-room-details.
//   testStoreReview       with the CI partner (scripts/audit/ios-partner.mjs): Report content on a partner message,
//                         Report room on a group the partner creates, and Settings → Manage account → Delete account.
//
// Every check prints "PSST-STORE|<id>|<ok|fail|na>|<note>". Test accounts only (qa-*), never real users.
//

import XCTest

@MainActor
final class PsstStoreTests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() async throws {
        continueAfterFailure = true
        app = Application.launch()
    }

    // MARK: - helpers

    private func record(_ id: String, _ ok: Bool?, _ note: String) {
        let status = ok == nil ? "na" : (ok! ? "ok" : "fail")
        print("PSST-STORE|\(id)|\(status)|\(note)")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "\(id)-\(status)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func diag(_ tag: String) {
        guard let root = try? app.snapshot() else { return }
        var out: [String] = []
        func walk(_ s: XCUIElementSnapshot) {
            if [.button, .staticText, .link, .textField, .secureTextField].contains(s.elementType), out.count < 90, !(s.label.isEmpty && s.identifier.isEmpty) {
                out.append("\(s.identifier)|\(s.label.prefix(60))")
            }
            for c in s.children { walk(c) }
        }
        walk(root)
        print("PSST-DIAG|\(tag)|" + out.joined(separator: " ; "))
    }

    private func texts(_ fragment: String, in root: XCUIApplication? = nil) -> XCUIElementQuery {
        (root ?? app!).descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment))
    }

    @discardableResult
    private func tapAny(_ labels: [String], in root: XCUIApplication? = nil, timeout: TimeInterval = 5) -> Bool {
        let r = root ?? app!
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for l in labels {
                for q in [r.buttons[l].firstMatch, r.links[l].firstMatch, r.staticTexts[l].firstMatch] where q.exists && q.isHittable {
                    q.tap(); return true
                }
            }
            usleep(400_000)
        } while Date() < deadline
        return false
    }

    @discardableResult
    private func tapContaining(_ fragments: [String], in root: XCUIApplication? = nil, timeout: TimeInterval = 5) -> Bool {
        let r = root ?? app!
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for f in fragments {
                let p = NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS %@", f, f)
                for q in [r.buttons, r.links, r.staticTexts] {
                    if let b = q.matching(p).allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { b.tap(); return true }
                }
            }
            usleep(400_000)
        } while Date() < deadline
        return false
    }

    private func allowSystemAlerts() {
        for _ in 0..<3 { _ = tapAny(["Allow", "Allow While Using App", "OK"], in: springboard, timeout: 1) }
    }

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

    private func saveShot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let att = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        att.name = name
        att.lifetime = .keepAlways
        add(att)
        if let dir = env["PSST_SHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? png.write(to: url)
            print("PSST-STORE|shot_\(name)|ok|\(url.path)")
        }
    }

    // MARK: - sign-in

    private func login() -> Bool {
        let signIn = app.buttons[A11yIdentifiers.authenticationStartScreen.signIn]
        guard signIn.waitForExistence(timeout: 30) else { record("login", false, "chýba Sign in"); return false }
        signIn.tap()
        _ = tapAny([A11yIdentifiers.serverConfirmationScreen.continue, "Continue"], timeout: 8)
        _ = tapAny(["Continue"], in: springboard, timeout: 30)
        let user = safari.textFields["Username"].firstMatch
        guard user.waitForExistence(timeout: 60) else { record("login", false, "MAS formulár sa neotvoril"); return false }
        let pw = safari.secureTextFields["Password"].firstMatch
        for _ in 1...3 {
            setField(user, app.username, secure: false)
            _ = tapAny(["Done"], in: safari, timeout: 2)
            setField(pw, app.password, secure: true)
            _ = tapAny(["Done"], in: safari, timeout: 2)
            _ = tapAny(["Continue"], in: safari, timeout: 5)
            sleep(3)
            _ = tapAny(["Not Now"], timeout: 2) || tapAny(["Not Now"], in: springboard, timeout: 2) || tapAny(["Not Now"], in: safari, timeout: 2)
            let invalid = safari.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'invalid'")).firstMatch
            if !(invalid.exists && user.exists) { break }
        }
        _ = tapAny(["Not Now"], timeout: 5)
        _ = tapAny(["Continue"], in: safari, timeout: 20)
        allowSystemAlerts()
        return true
    }

    /// After sign-in: identity confirmation with the recovery key (if given), the psst "Notifications & calls"
    /// screen that opens itself on first run, system alerts — until the room list is there.
    private func reachHome(recoveryKey: String?) -> Bool {
        let home = app.buttons[A11yIdentifiers.homeScreen.userAvatar]
        let deadline = Date().addingTimeInterval(300)
        var usedKey = false
        var homeSince: Date?
        while Date() < deadline {
            allowSystemAlerts()
            if let key = recoveryKey, !usedKey, tapContaining(["Enter recovery key", "Enter your recovery key", "Use recovery key", "recovery key"], timeout: 1) {
                let field = app.secureTextFields[A11yIdentifiers.secureBackupRecoveryKeyScreen.recoveryKeyField].firstMatch.exists
                    ? app.secureTextFields[A11yIdentifiers.secureBackupRecoveryKeyScreen.recoveryKeyField].firstMatch
                    : app.textFields[A11yIdentifiers.secureBackupRecoveryKeyScreen.recoveryKeyField].firstMatch
                if field.waitForExistence(timeout: 15) {
                    field.tap()
                    field.typeText(key)
                    _ = tapAny([A11yIdentifiers.secureBackupRecoveryKeyScreen.confirm, "Continue", "Confirm"], timeout: 5)
                    usedKey = true
                    record("recovery_key", true, "identita potvrdená kľúčom na obnovenie")
                    sleep(8)
                } else { diag("recovery-field") }
            }
            if tapAny(["psst_nc-done"], timeout: 1) { sleep(1) }
            _ = tapAny(["Not now", "Close", "Remind me later", "Skip", "Later"], timeout: 1)
            // with a recovery key: the home screen can come first and the "Enter your recovery key" banner a bit later
            // (iPad) — wait for it up to 90 s after home appeared
            if home.exists, home.isHittable {
                if recoveryKey == nil || usedKey { return true }
                if homeSince == nil { homeSince = Date() }
                if let t = homeSince, Date().timeIntervalSince(t) > 90 { record("recovery_key", false, "výzva na kľúč na obnovenie sa neobjavila"); return true }
            }
            usleep(800_000)
        }
        diag("reach-home")
        return home.exists
    }

    private func openRoom(_ name: String) -> Bool {
        let row = texts(name).firstMatch
        guard row.waitForExistence(timeout: 60) else { diag("room-list"); return false }
        row.tap()
        return app.textViews[A11yIdentifiers.roomScreen.messageComposer].firstMatch.waitForExistence(timeout: 40)
    }

    private func back() {
        let b = app.navigationBars.buttons.element(boundBy: 0)
        if b.exists, b.isHittable { b.tap() } else { _ = tapAny(["Back", "Chats"], timeout: 3) }
        sleep(1)
    }

    // MARK: - App Store screenshots

    func testStoreScreenshots() {
        guard login() else { return }
        let key = env["PSST_RECOVERY_KEY"]
        guard reachHome(recoveryKey: (key?.isEmpty ?? true) ? nil : key) else { record("home", false, "zoznam konverzácií sa neobjavil"); return }
        // give the app time to download the room keys from the backup and decrypt the last messages
        let lastGroup = env["PSST_SHOT_GROUP_LAST"] ?? "Can't wait"
        _ = texts(lastGroup).firstMatch.waitForExistence(timeout: 120)
        sleep(5)
        saveShot("1-chats")
        let group = env["PSST_SHOT_GROUP"] ?? "Weekend in the Tatras"
        if openRoom(group) {
            _ = texts(lastGroup).firstMatch.waitForExistence(timeout: 60)
            app.swipeDown()  // keyboard / composer focus away
            sleep(3)
            saveShot("2-group")
            if tapAny([A11yIdentifiers.roomScreen.name], timeout: 5) {
                sleep(3)
                saveShot("4-room-details")
                back()
            }
            back()
        } else { record("group", false, "skupina \(group) sa nenašla") }
        let dm = env["PSST_SHOT_DM"] ?? "Marek Novák"
        if openRoom(dm) {
            _ = texts(env["PSST_SHOT_DM_LAST"] ?? "Call after lunch").firstMatch.waitForExistence(timeout: 60)
            sleep(3)
            saveShot("3-chat")
            back()
        } else { record("dm", false, "konverzácia \(dm) sa nenašla") }
        record("screens", true, "snímky hotové")
    }

    // MARK: - review checks: report message, report room, delete account

    private var partner: String { env["PSST_AUDIT_PARTNER"] ?? "" }

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
        let composer = app.textViews[A11yIdentifiers.roomScreen.messageComposer].firstMatch
        if composer.waitForExistence(timeout: 10) { return true }   // an existing DM opens directly
        _ = tapAny(["Send invite", "Create", "Start"], timeout: 8)
        return composer.waitForExistence(timeout: 60)
    }

    private func send(_ text: String) {
        let composer = app.textViews[A11yIdentifiers.roomScreen.messageComposer].firstMatch
        guard composer.waitForExistence(timeout: 20) else { return }
        for _ in 0..<4 {
            composer.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 4) { composer.typeText(text); break }
        }
        app.buttons[A11yIdentifiers.roomScreen.sendButton].firstMatch.tap()
    }

    func testStoreReview() {
        guard login(), reachHome(recoveryKey: nil) else { record("home", false, "prihlásenie zlyhalo"); return }
        let id = String(Int(Date().timeIntervalSince1970) % 100_000)

        // 1. report a message of the partner
        if startDirectChat() {
            send("ping:\(id) report test")
            let pong = texts("pong:\(id)").firstMatch
            if pong.waitForExistence(timeout: 120) {
                let bubble = texts("pong:\(id)").allElementsBoundByIndex.last { $0.exists && $0.isHittable } ?? pong
                bubble.press(forDuration: 1.2)
                sleep(1)
                if !tapContaining(["Report content"], timeout: 2) { app.swipeUp(); sleep(1) }
                if app.navigationBars.staticTexts["Report content"].exists || tapContaining(["Report content", "Report"], timeout: 6) {
                    sleep(2)
                    // the room composer stays in the hierarchy behind the sheet → take the other text view
                    let notComposer = NSPredicate(format: "identifier != %@", A11yIdentifiers.roomScreen.messageComposer)
                    let visible = (app.textViews.matching(notComposer).allElementsBoundByIndex + app.textFields.allElementsBoundByIndex)
                        .filter { $0.exists && $0.frame.height > 10 && $0.frame.width > 50 }
                    print("PSST-DIAG|report-fields|\(visible.map { "\($0.elementType.rawValue) \($0.frame) \($0.identifier)" })")
                    if let reason = visible.last {
                        reason.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(1)
                        if app.keyboards.firstMatch.waitForExistence(timeout: 5) { app.typeText("Spam from iOS test (QA)") }
                    }
                    sleep(1)
                    saveShot("review-report-content")
                    let sent = tapAny(["Send"], timeout: 8)
                    sleep(4)
                    record("report_message", sent, sent ? "podržať správu → Report content → dôvod → Send" : "tlačidlo Send chýba")
                } else { diag("report-menu"); record("report_message", false, "v menu správy chýba Report") }
            } else { record("report_message", false, "partner neodpovedal (pong)") }
            // ask the partner for a group (it creates "QA ios group <id>" and invites us)
            send("MAKE-GROUP:\(id)")
            back()
        } else { record("report_message", false, "DM s partnerom sa nepodarilo založiť") }

        // 2. report a room (only offered for groups, not for DMs)
        let groupName = "QA ios group \(id)"
        let invite = texts(groupName).firstMatch
        if invite.waitForExistence(timeout: 120) {
            invite.tap()
            _ = tapAny(["Accept", "Join"], timeout: 15)
            sleep(5)
            if tapAny([A11yIdentifiers.roomScreen.name], timeout: 15) || tapContaining([groupName], timeout: 5) {
                sleep(2)
                let row = app.buttons["Report room"].firstMatch
                for _ in 0..<5 where !(row.exists && row.isHittable) { app.swipeUp(); sleep(1) }
                if row.exists, row.isHittable {
                    row.tap()
                    let reason = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
                    if reason.waitForExistence(timeout: 10) { reason.tap(); reason.typeText("Spam room from iOS test (QA)") }
                    sleep(1)
                    saveShot("review-report-room")
                    let ok = tapAny(["Report"], timeout: 8)
                    sleep(4)
                    record("report_room", ok, ok ? "detail skupiny → Report room → dôvod → Report" : "tlačidlo Report chýba")
                } else { diag("room-details"); record("report_room", false, "v detaile skupiny chýba Report room") }
                back(); back()
            } else { record("report_room", false, "detail skupiny sa neotvoril") }
        } else { record("report_room", false, "pozvánka do skupiny od partnera neprišla") }

        // 3. About: delete-account page and contact (D87)
        let avatar = app.buttons[A11yIdentifiers.homeScreen.userAvatar]
        if avatar.waitForExistence(timeout: 20) {
            avatar.tap()
            sleep(2)
            let about = app.buttons[A11yIdentifiers.settingsScreen.about].firstMatch
            for _ in 0..<4 where !(about.exists && about.isHittable) { app.swipeUp(); sleep(1) }
            if about.exists, about.isHittable {
                about.tap(); sleep(2)
                let del = texts("psst.pro/delete-account").firstMatch.exists, contact = texts("psst@psst.pro").firstMatch.exists
                saveShot("review-about")
                record("about_links", del && contact, "O aplikácii: zmazanie účtu \(del ? "je" : "chýba"), kontakt \(contact ? "je" : "chýba")")
                back()
            } else { diag("settings"); record("about_links", false, "About sa nenašlo") }
            app.swipeDown(); sleep(1)

            // 4. delete the account: Settings → Manage account & devices → MAS account page → Delete account
            let manage = app.buttons[A11yIdentifiers.settingsScreen.account].firstMatch
            for _ in 0..<4 where !(manage.exists && manage.isHittable) { app.swipeDown(); sleep(1) }
            if manage.exists, manage.isHittable {
                let label = manage.label
                manage.tap()
                sleep(8)
                let roots: [XCUIApplication] = [app, safari]
                var found = false
                for _ in 0..<8 where !found {
                    for r in roots {
                        let el = r.descendants(matching: .any).matching(NSPredicate(format: "label == 'Delete account'")).firstMatch
                        if el.exists, el.frame.height > 0 { el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); found = true; break }
                    }
                    if !found { safari.webViews.firstMatch.exists ? safari.webViews.firstMatch.swipeUp() : safari.swipeUp(); sleep(1) }
                }
                saveShot("review-delete-account")
                if found {
                    sleep(3)
                    // MAS asks to confirm (and may ask for the password or to type the username)
                    for r in roots {
                        let pw = r.secureTextFields.firstMatch
                        if pw.exists { pw.tap(); pw.typeText(app.password) }
                        let tf = r.textFields.firstMatch
                        if tf.exists, tf.isHittable { tf.tap(); tf.typeText(app.username) }
                    }
                    saveShot("review-delete-confirm")
                    var confirmed = false
                    for r in roots {
                        let b = r.descendants(matching: .any).matching(NSPredicate(format: "label IN {'Delete account', 'Delete', 'Confirm', 'Yes, delete'} AND elementType == %d", XCUIElement.ElementType.button.rawValue)).allElementsBoundByIndex.last
                        if let b, b.exists { b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); confirmed = true; break }
                    }
                    if !confirmed { for r in roots { print("PSST-DIAG|mas-confirm|\(r.descendants(matching: .any).allElementsBoundByIndex.prefix(80).map { "\($0.elementType.rawValue):\($0.label)" }.filter { !$0.hasSuffix(":") }.joined(separator: " ; "))") } }
                    sleep(8)
                    saveShot("review-deleted")
                    record("delete_account", confirmed, "Nastavenia → \(label) → stránka účtu → Delete account → potvrdenie (\(confirmed ? "odoslané" : "potvrdenie sa nenašlo"); výsledok overí server)")
                } else {
                    for r in roots { print("PSST-DIAG|mas-page|\(r.descendants(matching: .any).allElementsBoundByIndex.prefix(60).map { $0.label }.filter { !$0.isEmpty }.joined(separator: " ; "))") }
                    record("delete_account", false, "na stránke účtu sa nenašlo Delete account")
                }
            } else { diag("settings"); record("delete_account", false, "v Nastaveniach chýba Manage account") }
        }
    }
}
