//
// PSST: accessor for the psst strings table ElementX/Resources/Localizations/{en,sk}.lproj/Psst.strings.
// The table is not touched by Localazy (localazy.json only writes Localizable.*), so psst texts survive a sync.
// Other languages fall back to English (L10n.tr walks the preferred languages, then the development language).
// Shared with the NSE and the share extension (they resolve strings from the main app bundle, Bundle.app).
//

import Foundation

nonisolated enum PsstL10n {
    static func tr(_ key: String) -> String {
        L10n.tr("Psst", key)
    }

    static func tr(_ key: String, _ argument: String) -> String {
        L10n.tr("Psst", key, argument)
    }

    static func tr(_ key: String, _ first: String, _ second: String) -> String {
        L10n.tr("Psst", key, first, second)
    }
}
