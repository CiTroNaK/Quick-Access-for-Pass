import AppKit

/// Fits a requester authorization panel to its measured content, preserving width and the top edge when possible.
@MainActor enum AuthorizationPanelSizing {
    /// Preserves width and the top edge when possible; otherwise repositions within visible screen bounds.
    static func resize(_ panel: NSPanel, contentHeight: CGFloat) {
        guard contentHeight.isFinite, contentHeight > 0 else { return }
        let currentFrame = panel.frame
        let currentContentSize = panel.contentView?.bounds.size ?? currentFrame.size
        let requestedContentSize = NSSize(width: currentContentSize.width, height: contentHeight)
        var frameSize = panel.frameRect(forContentRect: NSRect(origin: .zero, size: requestedContentSize)).size
        guard frameSize.height.isFinite, frameSize.height > 0 else { return }

        let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
        if let visibleFrame {
            frameSize.height = min(frameSize.height, visibleFrame.height)
        }
        guard abs(frameSize.height - currentFrame.height) > 0.5 else { return }

        var frame = currentFrame
        frame.size.height = frameSize.height
        frame.origin.y = currentFrame.maxY - frame.height
        if let visibleFrame {
            frame.origin.y = min(
                max(frame.origin.y, visibleFrame.minY),
                visibleFrame.maxY - frame.height
            )
        }
        panel.setFrame(frame, display: true, animate: false)
    }
}
