import SwiftUI

/// Readable scope details within the authorization panel's constrained content width.
struct RunAuthScopeText: View {
    let text: String

    var body: some View {
        Text(text)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
