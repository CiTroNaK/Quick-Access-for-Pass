import Foundation

/// Reference box for capturing error messages emitted by a
/// coordinator's `onError` callback during tests. A reference type
/// is necessary because the callback runs on MainActor and
/// Swift doesn't let us `inout`-capture a local array into the
/// closure literal.
///
/// No `@testable import Quick_Access_for_Pass` here — this helper
/// references nothing from the main module. Test files that use it
/// already have their own `@testable import`.
@MainActor
final class ErrorBox {
    var messages: [String] = []
}
