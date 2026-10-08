//
//  SettingsHelpers.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import SwiftUI

func customBadge(text: LocalizedStringKey) -> some View {
    Text(text)
        .foregroundStyle(.secondary)
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color(nsColor: .secondarySystemFill))
        .clipShape(.capsule)
}

func HelpText(_ text: LocalizedStringKey) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
}
