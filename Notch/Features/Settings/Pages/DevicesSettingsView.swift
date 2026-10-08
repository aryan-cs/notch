//
//  DevicesSettingsView.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Defaults
import SwiftUI

struct DevicesSettingsView: View {
    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showDevicesTab) {
                    Text("Show devices button")
                }
            } footer: {
                Text("The headphones button next to the battery opens your devices: connect Bluetooth devices and choose where sound plays. Battery levels appear for devices that report them to your Mac, like AirPods, Beats, and Magic accessories; many speakers don't.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Devices")
    }
}
