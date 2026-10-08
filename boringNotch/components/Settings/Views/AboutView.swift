//
//  AboutView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import SwiftUI

struct AboutView: View {
    @State private var showBuildNumber: Bool = false

    /// The exact version this build reports, e.g. "1.0.1 (build 2)".
    private var reportVersion: String {
        let version = Bundle.main.releaseVersionNumber ?? "unknown"
        let build = Bundle.main.buildVersionNumber ?? "unknown"
        return "\(version) (build \(build))"
    }

    /// Opens the bug report form with the version fields prefilled via the
    /// issue form query parameter API. Keys must match the form field ids;
    /// renaming the template or its version fields breaks shipped apps.
    private var bugReportURL: URL? {
        var components = URLComponents(string: NotchRepository.newIssue)
        components?.queryItems = [
            URLQueryItem(name: "template", value: "1-bug-report-form.yml"),
            URLQueryItem(name: "version", value: reportVersion),
            URLQueryItem(
                name: "operating-system",
                value: ProcessInfo.processInfo.operatingSystemVersionString
            ),
        ]
        return components?.url
    }

    var body: some View {
        VStack {
            Form {
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        if showBuildNumber {
                            Text("(\(Bundle.main.buildVersionNumber ?? ""))")
                                .foregroundStyle(.secondary)
                        }
                        Text(Bundle.main.releaseVersionNumber ?? "unknown")
                            .foregroundStyle(.secondary)
                    }
                    .onTapGesture {
                        withAnimation {
                            showBuildNumber.toggle()
                        }
                    }
                } header: {
                    Text("Version info")
                }

                UpdaterSettingsView()

                HStack(spacing: 30) {
                    Spacer(minLength: 0)
                    Button {
                        if let url = bugReportURL {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "exclamationmark.bubble")
                                .font(.system(size: 15, weight: .medium))
                                .frame(height: 18)
                            Text("Report a Bug")
                        }
                        .contentShape(Rectangle())
                    }
                    .help("Open a bug report with your version filled in automatically")
                    Button {
                        NSWorkspace.shared.open(NotchRepository.url)
                    } label: {
                        VStack(spacing: 5) {
                            Image("Github")
                                .resizable().scaledToFit()
                                .frame(width: 18, height: 18)
                                .foregroundStyle(.primary)
                            Text("GitHub")
                        }
                        .contentShape(Rectangle())
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(PlainButtonStyle())
            }
            VStack(spacing: 0) {
                Divider()
                Text("Built on boring.notch by TheBoredTeam")
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                    .padding(.bottom, 7)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .toolbar {
            CheckForUpdatesView()
        }
        .navigationTitle("About")
    }
}
