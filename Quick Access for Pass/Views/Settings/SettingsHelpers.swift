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
        settingsRowContent(label: label.map { Text($0) }, control: control)
    }

    static func settingsRow<Control: View>(
        label: Text,
        @ViewBuilder control: () -> Control
    ) -> some View {
        settingsRowContent(label: label, control: control)
    }

    private static func settingsRowContent<Control: View>(
        label: Text?,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack {
            if let label {
                label
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer()
            control()
        }
    }
}
