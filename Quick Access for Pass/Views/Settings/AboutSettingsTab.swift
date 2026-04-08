import SwiftUI

struct AboutSettingsTab: View {
    @State private var showingLicenses = false

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            Text("Quick Access for Pass")
                .font(.headline)

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
               let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                Text("Version \(version) (\(build))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("by Petr Hlavicka")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Link("petr.codes", destination: URL(string: "https://petr.codes")!)
                    .font(.caption)
                Link("yes@petr.codes", destination: URL(string: "mailto:yes@petr.codes")!)
                    .font(.caption)
            }

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 2) {
                Text("This app does not check for updates automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Check for new releases on GitHub",
                     destination: URL(string: "https://github.com/CiTroNaK/Quick-Access-for-Pass/releases")!)
                    .font(.caption)
            }

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 2) {
                Text("This app is not affiliated with or endorsed by Proton AG.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Proton Pass is a trademark of Proton AG.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()
                .padding(.horizontal, 40)

            Button("Open Source Licenses") {
                showingLicenses = true
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .sheet(isPresented: $showingLicenses) {
            LicensesView()
        }
    }
}
