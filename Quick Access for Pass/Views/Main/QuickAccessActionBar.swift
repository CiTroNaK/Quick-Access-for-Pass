import AppKit
import SwiftUI

struct QuickAccessActionBar: View {
    @Bindable var viewModel: QuickAccessViewModel

    private var footerItems: [QuickAccessFooterItem] {
        if let error = viewModel.errorMessage {
            return QuickAccessFooterContent.resultsItems(
                actions: [],
                isLoading: false,
                errorContext: .init(message: error, copyDetails: copyErrorDetails(error: error))
            )
        }

        guard let item = viewModel.items[safe: viewModel.selectedIndex] else {
            return []
        }

        let actions = viewModel.actionsForItem(item)
        let descriptors = actions.prefix(2).map { action in
            QuickAccessFooterActionDescriptor(
                intent: .itemAction(action.action),
                title: action.label,
                shortcut: action.shortcut
            )
        }
        let trailingDescriptor: QuickAccessFooterActionDescriptor? =
            actions.count > 2
            ? .init(intent: .showDetail, title: String(localized: "More actions"), shortcut: "→")
            : nil

        return QuickAccessFooterContent.resultsItems(
            actions: descriptors + (trailingDescriptor.map { [$0] } ?? []),
            isLoading: viewModel.isActionLoading,
            errorContext: nil
        )
    }

    var body: some View {
        QuickAccessFooter(
            leadingItems: footerItems,
            trailingItem: nil
        ) { intent in
            handle(intent)
        }
    }

    @MainActor
    private func handle(_ intent: QuickAccessFooterActionIntent) {
        switch intent {
        case .itemAction(let action):
            guard let item = viewModel.items[safe: viewModel.selectedIndex] else { return }
            viewModel.handleAction(action, for: item)
        case .showDetail:
            viewModel.showDetail()
        case .copyError(let details):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(details, forType: .string)
        case .dismissError:
            viewModel.errorMessage = nil
        }
    }

    private func copyErrorDetails(error: String) -> String {
        """
        Error: \(error)
        CLI path: \(viewModel.cliPath)
        Last command: \(viewModel.lastCommand)
        """
    }
}
