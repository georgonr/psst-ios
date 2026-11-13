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
    
    var body: some View {
        Form {
            Section {
                ListRow(label: .plain(title: L10n.commonCopyright),
                        kind: .button { openURL(context.viewState.copyrightURL) })
                ListRow(label: .plain(title: L10n.commonAcceptableUsePolicy),
                        kind: .button { openURL(context.viewState.acceptableUseURL) })
                ListRow(label: .plain(title: L10n.commonPrivacyPolicy),
                        kind: .button { openURL(context.viewState.privacyURL) })
            }
            
            // PSST: AGPL-3.0 §13 - offer the corresponding source of this modified build.
            Section {
                ListRow(label: .plain(title: "Source code (AGPL-3.0)", // swiftlint:disable:this hardcoded_string
                                      description: "github.com/georgonr/psst-ios"), // swiftlint:disable:this hardcoded_string
                        kind: .button { openURL(context.viewState.sourceCodeURL) })
            } footer: {
                Text("psst is a modified build of Element X iOS by Element Creations Ltd / New Vector Ltd, licensed under AGPL-3.0.") // swiftlint:disable:this hardcoded_string
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
