import SwiftUI

struct ShortcutHint: View {
    let keys: String
    let label: LocalizedStringKey

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .appGlassEffect(cornerRadius: 4)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
