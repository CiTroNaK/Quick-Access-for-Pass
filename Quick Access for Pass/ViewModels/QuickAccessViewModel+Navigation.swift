import AppKit

extension QuickAccessViewModel {
    func showDetail() {
        onActivity()
        guard let item = items[safe: selectedIndex] else { return }
        detailItem = item
        selectedRowIndex = 0
    }

    func hideDetail() {
        onActivity()
        inFlightCopy?.cancel()
        inFlightCopy = nil
        inFlightLargeType?.cancel()
        inFlightLargeType = nil
        isActionLoading = false
        copyGeneration += 1
        largeTypeGeneration += 1
        detailItem = nil
        selectedRowIndex = 0
    }

    func moveRowSelection(by offset: Int) {
        onActivity()
        guard let item = detailItem else { return }
        let rows = rows(for: item)
        guard !rows.isEmpty else { return }

        let proposed = max(0, min(rows.count - 1, selectedRowIndex + offset))
        let direction = offset >= 0 ? 1 : -1
        var index = proposed
        while index >= 0 && index < rows.count && !rows[index].isSelectable {
            let next = index + direction
            if next < 0 || next >= rows.count { break }
            index = next
        }
        if index >= 0 && index < rows.count && rows[index].isSelectable {
            selectedRowIndex = index
        }
    }

    func moveSelection(by offset: Int) {
        onActivity()
        guard !items.isEmpty else { return }
        selectedIndex = max(0, min(items.count - 1, selectedIndex + offset))
    }

    /// Unified list of detail rows: today's named actions (top group) followed
    /// by the field rows derived from `item.fieldKeys`. Section-header row
    /// identity includes the header's ordinal position so two sections that
    /// happen to share a name produce distinct IDs for diffing/scroll targeting.
    func rows(for item: PassItem) -> [DetailRow] {
        var rows: [DetailRow] = actionsForItem(item).map { tuple in
            .namedAction(action: tuple.action, label: tuple.label, shortcut: tuple.shortcut)
        }
        var sectionOrdinal = 0
        for key in item.fieldKeys {
            switch key {
            case .sectionHeader(let name):
                rows.append(.sectionHeader(name: name, id: "\(sectionOrdinal):\(name)"))
                sectionOrdinal += 1
            default:
                rows.append(.field(key: key, label: key.localizedLabel, isSensitive: key.isSensitive))
            }
        }
        return rows
    }

    /// Called by the local NSEvent monitor in PanelController. Returns `true` if the event
    /// matched a configured copy shortcut and was handled.
    func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let item = detailItem ?? items[safe: selectedIndex]
        guard let item else { return false }

        let largeTypeCode = UInt16(defaults.integer(forKey: DefaultsKey.showLargeTypeKeyCode))
        let largeTypeMods = NSEvent.ModifierFlags(
            rawValue: UInt(defaults.integer(forKey: DefaultsKey.showLargeTypeModifiers))
        ).intersection([.command, .shift, .option, .control])
        if detailItem != nil, keyCode == largeTypeCode, modifiers == largeTypeMods {
            onActivity()
            showSelectedRowInLargeType()
            return true
        }

        let shortcuts: [(codeKey: String, modsKey: String, action: ItemAction)] = [
            (DefaultsKey.copyUsernameKeyCode, DefaultsKey.copyUsernameModifiers, .copyUsername),
            (DefaultsKey.copyPasswordKeyCode, DefaultsKey.copyPasswordModifiers, .copyPassword),
            (DefaultsKey.copyTotpKeyCode, DefaultsKey.copyTotpModifiers, .copyTotp),
        ]

        for shortcut in shortcuts {
            let storedCode = UInt16(defaults.integer(forKey: shortcut.codeKey))
            let storedMods = NSEvent.ModifierFlags(
                rawValue: UInt(defaults.integer(forKey: shortcut.modsKey))
            ).intersection([.command, .shift, .option, .control])
            let action = shortcut.action
            if keyCode == storedCode && modifiers == storedMods {
                onActivity()
                if detailItem != nil {
                    let rows = rows(for: item)
                    if let index = rows.firstIndex(where: {
                        if case .namedAction(let current, _, _) = $0 { return current == action }
                        return false
                    }) {
                        selectedRowIndex = index
                    }
                }
                handleAction(action, for: item)
                return true
            }
        }
        return false
    }
}
