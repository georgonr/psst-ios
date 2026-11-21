# psst iOS — Element remnants (D94, 26.11.1)

Places where a user could see "Element", "Element X", "ElementX" or Element branding, and what was done.

## Fixed

| Place | Was | Now |
|---|---|---|
| `ElementX/Resources/Localizations/*.lproj/InfoPlist.strings` (they override Info.plist) — camera, microphone, location prompts | "… Element X needs access to the camera / microphone", "… so that Element X can share your location" (40 locales) | en, en-US, sk: psst texts (location text per spec). All other locales were removed entirely in D98 (their Localizable.strings also said Element X and had no psst texts); a phone in another language gets English. |
| `localazy.json` | Localazy download wrote `InfoPlist.strings` for every language (would bring "Element X" back) | The two `InfoPlist.json` actions removed — Localazy writes only `Localizable.strings/.stringsdict`. psst strings live in the `Psst` table (`Psst.strings`, `PsstL10n`), which Localazy never touches. |
| `ElementX/SupportingFiles/target.yml` usage descriptions | upstream texts | psst texts; `NSLocationAlwaysAndWhenInUseUsageDescription` removed (psst never asks for Always, D97) |
| Notification sounds (`NotificationTone.swift`, `NotificationToneManager.swift`) | "Element Default", "Element Fade" | "psst default" / "psst fade" (SK "psst predvolený" / "psst doznievajúci"); also shown so for a tone stored by an older build |
| Legacy call invite in the timeline (`CallInviteRoomTimelineView`) | "Unsupported call. Ask if the caller can use the new Element X app." | "Unsupported call. Ask the caller to call again from the psst app." (SK in Psst.strings) |
| Help links (`AppSettings`: encryption, device verification, chat backup, identity pinning, history sharing) | element.io/help#… | https://psst.pro/support (exists, SK/EN, no per-topic anchors yet) |
| `PsstL10n` | defined inside the notifications screen, formatted arguments twice | own file `ElementX/Sources/Other/PsstL10n.swift`, shared with the NSE and share extension |

## Checked, nothing to change

- **CallKit** (`CXProviderConfiguration`): no `localizedName`, iOS uses the bundle display name `psst`.
- **CFBundleName / CFBundleDisplayName**: both `$(APP_DISPLAY_NAME)` = psst (D89). The executable/product name is still `ElementX` (`APP_NAME`), which iOS doesn't show.
- **Screen sharing prompt in calls ("Element X, file://")**: the embedded Element Call web view (`CallScreen.swift`) sets `applicationNameForUserAgent` to the bundle display name (psst); nothing in the app sets "Element X" for WKWebView, `getDisplayMedia` or the Element Call configuration. WebKit's prompt takes the app name from the bundle (CFBundleName was `ElementX` in build 3, now psst) and the origin of the bundled page (`file://`). The `file://` part is the local Element Call bundle and can't be changed from the app. **Re-check on a device**; if "Element X" still appears it comes from inside the EmbeddedElementCall/ElementCall packages (page title), not from this repo. There is no broadcast upload extension (none added).
- **Legal text** "psst is a modified build of Element X iOS by Element Creations Ltd / New Vector Ltd…" in About — kept on purpose (licence).
- **Developer options** text "Element Call web view" — developer options are hidden in release builds.

## Remaining (not reachable in psst, left as is)

- `screen_change_server_error_element_pro_required_*` ("Element Pro required") — only shown when a homeserver's well-known demands the Element Pro app; chat.psst.pro doesn't.
- `screen_missing_key_backup_*` ("Open Element Classic") — Element Classic migration is disabled (no classicApp* Info.plist keys).
- `screen_advanced_settings_element_call_base_url*` — not used by any screen.
- `call_invalid_audio_device_bluetooth_devices_disabled` — Android only.
- Previews / mocks / test fixtures mentioning Element (not in the app UI).

## D98 — Slovak and English only

`ElementX/Resources/Localizations/` keeps only `en.lproj`, `en-US.lproj` and `sk.lproj`; `Settings.bundle` keeps
only `en.lproj`. The other ~38 upstream translations are removed from the repository (not only from the IPA), so a
later upstream merge must not bring them back. `UnitTests/Sources/LocalizationTests.swift` checks sk instead of
it / de / hr.
