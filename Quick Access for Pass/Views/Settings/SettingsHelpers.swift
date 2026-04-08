import SwiftUI

enum SettingsLayout {
    @ViewBuilder
    static func settingsPane<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    static func settingsRow<Control: View>(
        label: LocalizedStringKey? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack {
            if let label {
                Text(label)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer()
            control()
        }
    }
}
