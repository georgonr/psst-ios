//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct LegalInformationScreen: View {
    let context: LegalInformationScreenViewModel.Context
    @Environment(\.openURL) private var openURL
    
    // PSST (D87)
    private static let psstTerms: URL = "https://psst.pro/terms"
    private static let psstPrivacy: URL = "https://psst.pro/privacy"
    private static let psstDeleteAccount: URL = "https://psst.pro/delete-account"
    private static let psstContact: URL = "mailto:psst@psst.pro"
    private static var sk: Bool { ["sk", "cs"].contains(Locale.current.language.languageCode?.identifier ?? "") }
    
    var body: some View {
        Form {
            Section {
                // PSST (D87): the legal pages live on psst.pro (AppSettings keeps app.psst.pro/*.html for the OAuth client
                // metadata, MAS wants them on the client_uri host; those addresses redirect here).
                // PSST (D99): psst's own copyright line
                ListRow(label: .plain(title: L10n.commonCopyright, description: "© 2026 GT"),
                        kind: .button { openURL(Self.psstTerms) })
                ListRow(label: .plain(title: L10n.commonAcceptableUsePolicy),
                        kind: .button { openURL(Self.psstTerms) })
                ListRow(label: .plain(title: L10n.commonPrivacyPolicy),
                        kind: .button { openURL(Self.psstPrivacy) })
            }
            
            // PSST (D87): App Store / Google Play — how to delete the account, and the operator's contact.
            Section {
                ListRow(label: .plain(title: Self.sk ? "Zmazanie účtu" : "Delete account",
                                      description: "psst.pro/delete-account"),
                        kind: .button { openURL(Self.psstDeleteAccount) })
                ListRow(label: .plain(title: Self.sk ? "Kontakt" : "Contact",
                                      description: "psst@psst.pro"),
                        kind: .button { openURL(Self.psstContact) })
            }
            
            // PSST: AGPL-3.0 §13 - offer the corresponding source of this modified build.
            Section {
                ListRow(label: .plain(title: "Source code (AGPL-3.0)",
                                      description: "github.com/georgonr/psst-ios"),
                        kind: .button { openURL(context.viewState.sourceCodeURL) })
            } footer: {
                Text("psst is a modified build of Element X iOS by Element Creations Ltd / New Vector Ltd, licensed under AGPL-3.0.")
                    .compoundListSectionFooter()
            }
        }
        .compoundList()
        .navigationTitle(L10n.commonAbout)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Previews

struct LegalInformationScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = LegalInformationScreenViewModel(userSettings: .mock())
    static var previews: some View {
        LegalInformationScreen(context: viewModel.context)
    }
}
