//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

nonisolated protocol CompoundHookProtocol: Sendable {
    @MainActor func override(colors: CompoundColors, uiColors: CompoundUIColors)
}

struct DefaultCompoundHook: CompoundHookProtocol {
    // PSST: brand accent colour #38BDF8 (sky-400) replaces Element's green accent tokens.
    func override(colors: CompoundColors, uiColors: CompoundUIColors) {
        let accent = UIColor(red: 0x38 / 255, green: 0xBD / 255, blue: 0xF8 / 255, alpha: 1)
        
        colors.override(\.iconAccentPrimary, with: Color(uiColor: accent))
        colors.override(\.iconAccentTertiary, with: Color(uiColor: accent))
        colors.override(\.textActionAccent, with: Color(uiColor: accent))
        colors.override(\.bgAccentRest, with: Color(uiColor: accent))
        colors.override(\.borderAccentPrimary, with: Color(uiColor: accent))
        
        uiColors.override(\.iconAccentPrimary, with: accent)
        uiColors.override(\.iconAccentTertiary, with: accent)
        uiColors.override(\.textActionAccent, with: accent)
        uiColors.override(\.bgAccentRest, with: accent)
        uiColors.override(\.borderAccentPrimary, with: accent)
    }
}
