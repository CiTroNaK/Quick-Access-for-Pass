import AppKit
import SwiftUI

/// Caller-owned transient content. Preparation never attaches the new secret to a window.
@MainActor
final class PreparedLargeTypePresentation {
    enum State { case prepared, presented, completed, discarded }

    let window: NSWindow
    let layout: LargeTypeView.Layout
    let ownsNewWindow: Bool
    weak var previousPanel: NSWindow?
    var hostingController: NSHostingController<LargeTypeView>?
    var state: State = .prepared
    var ownsRegistration = false
    weak var owner: LargeTypeWindowController?

    init(window: NSWindow, hostingController: NSHostingController<LargeTypeView>,
         layout: LargeTypeView.Layout, previousPanel: NSWindow?, ownsNewWindow: Bool,
         owner: LargeTypeWindowController) {
        self.window = window
        self.hostingController = hostingController
        self.layout = layout
        self.previousPanel = previousPanel
        self.ownsNewWindow = ownsNewWindow
        self.owner = owner
    }
}
