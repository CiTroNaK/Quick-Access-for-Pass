import AppKit
import SwiftUI

/// A native AppKit search control for Authentication Services presentation hosts.
/// It leaves query state and picker behavior in the SwiftUI parent.
@MainActor
struct AutoFillPickerSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusTarget: FocusState<AutoFillCandidatePickerFocusTarget?>.Binding

    let onMoveSelectionUp: @MainActor () -> Void
    let onMoveSelectionDown: @MainActor () -> Void
    let onFill: @MainActor () -> Void
    let onCancel: @MainActor () -> Void
    let onTab: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            focusTarget: focusTarget,
            onMoveSelectionUp: onMoveSelectionUp,
            onMoveSelectionDown: onMoveSelectionDown,
            onFill: onFill,
            onCancel: onCancel,
            onTab: onTab
        )
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.delegate = context.coordinator
        searchField.placeholderString = "Search credentials"
        searchField.sendsWholeSearchString = false
        searchField.setAccessibilityLabel("Search credentials")
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.update(
            text: $text,
            focusTarget: focusTarget,
            onMoveSelectionUp: onMoveSelectionUp,
            onMoveSelectionDown: onMoveSelectionDown,
            onFill: onFill,
            onCancel: onCancel,
            onTab: onTab
        )

        guard searchField.stringValue != text else {
            context.coordinator.focusIfRequested(searchField)
            return
        }
        searchField.stringValue = text
        context.coordinator.focusIfRequested(searchField)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private var text: Binding<String>
        private var focusTarget: FocusState<AutoFillCandidatePickerFocusTarget?>.Binding
        private var onMoveSelectionUp: @MainActor () -> Void
        private var onMoveSelectionDown: @MainActor () -> Void
        private var onFill: @MainActor () -> Void
        private var onCancel: @MainActor () -> Void
        private var onTab: @MainActor () -> Void

        init(
            text: Binding<String>,
            focusTarget: FocusState<AutoFillCandidatePickerFocusTarget?>.Binding,
            onMoveSelectionUp: @escaping @MainActor () -> Void,
            onMoveSelectionDown: @escaping @MainActor () -> Void,
            onFill: @escaping @MainActor () -> Void,
            onCancel: @escaping @MainActor () -> Void,
            onTab: @escaping @MainActor () -> Void
        ) {
            self.text = text
            self.focusTarget = focusTarget
            self.onMoveSelectionUp = onMoveSelectionUp
            self.onMoveSelectionDown = onMoveSelectionDown
            self.onFill = onFill
            self.onCancel = onCancel
            self.onTab = onTab
        }

        func update(
            text: Binding<String>,
            focusTarget: FocusState<AutoFillCandidatePickerFocusTarget?>.Binding,
            onMoveSelectionUp: @escaping @MainActor () -> Void,
            onMoveSelectionDown: @escaping @MainActor () -> Void,
            onFill: @escaping @MainActor () -> Void,
            onCancel: @escaping @MainActor () -> Void,
            onTab: @escaping @MainActor () -> Void
        ) {
            self.text = text
            self.focusTarget = focusTarget
            self.onMoveSelectionUp = onMoveSelectionUp
            self.onMoveSelectionDown = onMoveSelectionDown
            self.onFill = onFill
            self.onCancel = onCancel
            self.onTab = onTab
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            focusTarget.wrappedValue = .search
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField,
                  text.wrappedValue != searchField.stringValue else { return }
            text.wrappedValue = searchField.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                onMoveSelectionUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                onMoveSelectionDown()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                onFill()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true
            case #selector(NSResponder.insertTab(_:)):
                onTab()
                return true
            default:
                return false
            }
        }

        func focusIfRequested(_ searchField: NSSearchField) {
            guard focusTarget.wrappedValue == .search,
                  let window = searchField.window,
                  window.firstResponder !== searchField.currentEditor() else { return }
            DispatchQueue.main.async { [weak self, weak searchField] in
                guard let self,
                      self.focusTarget.wrappedValue == .search,
                      let searchField else { return }
                searchField.window?.makeFirstResponder(searchField)
            }
        }
    }
}
