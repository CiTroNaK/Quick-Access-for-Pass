import Foundation

/// Only `present` is a synchronized secret effect; other phases may re-enter app code.
@MainActor
struct LargeTypePresentationActions {
    let prepare: @MainActor @Sendable (LargeTypeDisplay) throws -> PreparedLargeTypePresentation
    let activate: @MainActor @Sendable (PreparedLargeTypePresentation) throws -> Void
    let present: @MainActor @Sendable (PreparedLargeTypePresentation) throws -> Void
    let complete: @MainActor @Sendable (PreparedLargeTypePresentation) -> Void
    let discard: @MainActor @Sendable (PreparedLargeTypePresentation) -> Void
}
