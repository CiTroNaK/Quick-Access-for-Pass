import SwiftUI

/// Hosts the existing remembered-decision controls using the Offline manager's sheet layout.
struct RememberedDecisionsManagerView<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 480)
    }
}
