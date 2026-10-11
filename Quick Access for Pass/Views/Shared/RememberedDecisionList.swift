import SwiftUI

struct RememberedDecisionList<Content: View>: View {
    private let accessibilityLabel: String
    private let content: Content

    init(
        accessibilityLabel: String,
        @ViewBuilder content: () -> Content
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 4) {
                content
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityLabel(accessibilityLabel)
    }
}
