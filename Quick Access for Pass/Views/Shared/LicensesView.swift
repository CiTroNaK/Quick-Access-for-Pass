import SwiftUI

private struct LicenseEntry: Decodable {
    let title: String
    let url: String
    let text: String
}

struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss

    private let licenses: [LicenseEntry] = {
        guard let url = Bundle.main.url(forResource: "licenses", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([LicenseEntry].self, from: data) else { return [] }
        return entries
    }()

    var body: some View {
        VStack(spacing: 0) {
            Text("Open Source Licenses")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(licenses.enumerated()), id: \.offset) { index, license in
                        if index > 0 { Divider() }
                        licenseSection(title: license.title, url: license.url, text: license.text)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 500, height: 420)
    }

    private func licenseSection(title: String, url: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Link(title, destination: URL(string: url)!)
                .font(.subheadline.bold())
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
