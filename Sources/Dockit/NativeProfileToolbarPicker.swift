import AppKit
import DockitCore
import SwiftUI

@MainActor
struct NativeProfileToolbarPicker: NSViewRepresentable {
    typealias NSViewType = NativeProfilePopUpButton

    @Bindable var model: AppModel
    @Environment(\.isEnabled) private var environmentEnabled
    @Environment(\.colorScheme) private var colorScheme

    init(model: AppModel) {
        self.model = model
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NativeProfilePopUpButton {
        let button = NativeProfilePopUpButton(frame: .zero, pullsDown: false)
        let menu = NSMenu(title: "docks")
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        button.menu = menu
        button.setAccessibilityLabel("choose dock")
        button.setAccessibilityIdentifier("profile-picker")
        return button
    }

    func updateNSView(_ button: NativeProfilePopUpButton, context: Context) {
        context.coordinator.update(
            model: model,
            button: button,
            environmentEnabled: environmentEnabled,
            colorScheme: colorScheme
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NativeProfilePopUpButton,
        context: Context
    ) -> CGSize? {
        nsView.measuredSize()
    }

    static func dismantleNSView(_ button: NativeProfilePopUpButton, coordinator: Coordinator) {
        button.menu?.delegate = nil
    }

    enum Command: Equatable {
        case inspect(UUID)
        case rename(UUID)
        case setColor(UUID, ProfileColor)
        case duplicate(UUID)
        case delete(UUID)
        case create(captureCurrent: Bool)
        case importProfiles
        case exportProfiles
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        private final class CommandBox: NSObject {
            let command: Command

            init(_ command: Command) {
                self.command = command
            }
        }

        private(set) var model: AppModel

        init(model: AppModel) {
            self.model = model
        }

        func update(
            model: AppModel,
            button: NativeProfilePopUpButton,
            environmentEnabled: Bool,
            colorScheme: ColorScheme
        ) {
            self.model = model
            guard let record = model.selectedRecord else {
                button.setDisplayedItem(title: "choose dock", image: nil)
                button.toolTip = "choose a saved dock to inspect or edit"
                button.setAccessibilityValue("")
                button.isEnabled = false
                return
            }

            let name = record.profile.name
            button.setDisplayedItem(title: name, image: record.profile.color.toolbarSwatchImage(for: colorScheme))
            button.toolTip = "choose a saved dock to inspect or edit: \(name)"
            button.setAccessibilityValue(name)
            button.setAccessibilityHelp("choose a saved dock to inspect or edit")
            button.isEnabled = environmentEnabled && !model.activationActionsDisabled
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            populate(menu, from: model)
        }

        @objc func performCommand(_ sender: NSMenuItem) {
            guard let command = (sender.representedObject as? CommandBox)?.command else { return }
            dispatch(command, on: model)
        }

        private func populate(_ menu: NSMenu, from model: AppModel) {
            menu.removeAllItems()
            let selectedID = model.selectedProfileID
            let activeID = model.library.activeProfile?.profileID
            let selectionEnabled = !model.activationActionsDisabled
            let profileActionsEnabled = !model.profileActionsDisabled

            for record in model.library.profiles {
                let title = record.id == activeID
                    ? "\(record.profile.name) · current"
                    : record.profile.name
                let item = commandItem(
                    title,
                    command: .inspect(record.id),
                    enabled: selectionEnabled
                )
                item.image = record.profile.color.menuSwatchImage
                item.state = record.id == selectedID ? .on : .off
                menu.addItem(item)
            }

            menu.addItem(.separator())
            guard let inspected = model.selectedRecord else { return }

            menu.addItem(commandItem(
                "rename...",
                command: .rename(inspected.id),
                enabled: profileActionsEnabled
            ))

            let colorItem = NSMenuItem(title: "color", action: nil, keyEquivalent: "")
            let colorMenu = NSMenu(title: "color")
            colorMenu.autoenablesItems = false
            for color in ProfileColor.allCases {
                let item = commandItem(
                    color.rawValue,
                    command: .setColor(inspected.id, color),
                    enabled: profileActionsEnabled
                )
                item.image = color.menuSwatchImage
                item.state = inspected.profile.color == color ? .on : .off
                colorMenu.addItem(item)
            }
            colorItem.submenu = colorMenu
            colorItem.isEnabled = profileActionsEnabled
            menu.addItem(colorItem)

            menu.addItem(commandItem(
                "duplicate",
                command: .duplicate(inspected.id),
                enabled: profileActionsEnabled
            ))
            menu.addItem(commandItem(
                "delete dock...",
                command: .delete(inspected.id),
                enabled: profileActionsEnabled && model.library.profiles.count > 1
            ))

            menu.addItem(.separator())
            menu.addItem(commandItem(
                "capture current dock",
                command: .create(captureCurrent: true),
                enabled: profileActionsEnabled
            ))
            menu.addItem(commandItem(
                "new empty dock",
                command: .create(captureCurrent: false),
                enabled: profileActionsEnabled
            ))

            menu.addItem(.separator())
            menu.addItem(commandItem(
                "import docks...",
                command: .importProfiles,
                enabled: profileActionsEnabled
            ))
            menu.addItem(commandItem(
                "export docks...",
                command: .exportProfiles,
                enabled: profileActionsEnabled
            ))
        }

        private func commandItem(
            _ title: String,
            command: Command,
            enabled: Bool
        ) -> NSMenuItem {
            let item = NSMenuItem(
                title: title,
                action: #selector(performCommand(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = CommandBox(command)
            item.isEnabled = enabled
            return item
        }

        private func dispatch(_ command: Command, on model: AppModel) {
            switch command {
            case let .inspect(id):
                guard !model.activationActionsDisabled, model.library.record(id: id) != nil else { return }
                model.selectedProfileID = id
            case let .rename(id):
                model.promptToRenameProfile(id)
            case let .setColor(id, color):
                model.colorProfile(id, color: color)
            case let .duplicate(id):
                Task { await model.duplicateProfile(id) }
            case let .delete(id):
                model.askToDeleteProfile(id)
            case let .create(captureCurrent):
                Task { await model.createProfile(captureCurrent: captureCurrent) }
            case .importProfiles:
                Task { await model.importProfiles(from: .management) }
            case .exportProfiles:
                model.presentExport(from: .management)
            }
        }
    }
}

@MainActor
final class NativeProfilePopUpButton: NSPopUpButton {
    static let minimumWidth: CGFloat = 104
    static let maximumWidth: CGFloat = 340
    static let backingHorizontalInset: CGFloat = 10
    /// A 36 pt pill, thicker than a stock toolbar control, matching the
    /// design reference for the editor.
    static let controlHeight: CGFloat = 36
    /// Extra top padding on the toolbar item. The pill's center sits 4 pt
    /// below the traffic lights' center, as in the reference.
    static let toolbarTopOffset: CGFloat = 8

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: false)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var intrinsicContentSize: NSSize {
        measuredSize()
    }

    var displayedMenuItem: NSMenuItem? {
        (cell as? NSPopUpButtonCell)?.menuItem
    }

    func setDisplayedItem(title: String, image: NSImage?) {
        guard let popupCell = cell as? NSPopUpButtonCell else { return }
        let item = popupCell.menuItem
            ?? NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.title = title
        item.image = image
        popupCell.menuItem = item
        self.title = title
        self.image = image
        popupCell.needsSizing = true
        popupCell.needsDisplay = true
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    func measuredSize() -> NSSize {
        let natural = super.intrinsicContentSize
        guard let popupCell = cell as? NSPopUpButtonCell else {
            return natural
        }
        let naturalBounds = NSRect(
            x: 0,
            y: 0,
            width: max(Self.minimumWidth, natural.width),
            height: max(Self.controlHeight, natural.height)
        )
        let nativeTitleRect = popupCell.titleRect(forBounds: naturalBounds)
        let horizontalInsets = naturalBounds.width - nativeTitleRect.width
        let titleWidth = ceil(popupCell.attributedTitle.size().width)
        let width = min(
            max(ceil(titleWidth + horizontalInsets), Self.minimumWidth),
            Self.maximumWidth
        )
        let bounds = NSRect(x: 0, y: 0, width: width, height: naturalBounds.height)
        let wrapped = popupCell.cellSize(forBounds: bounds)
        return NSSize(width: width, height: ceil(max(Self.controlHeight, wrapped.height)))
    }

    private func configure() {
        let popupCell = NativeWrappingPopUpButtonCell(textCell: "", pullsDown: false)
        popupCell.menuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        cell = popupCell
        usesItemFromMenu = false
        altersStateOfSelectedItem = false
        autoenablesItems = false
        controlSize = .large
        font = .systemFont(ofSize: 13, weight: .semibold)
        isBordered = false
        bezelStyle = .flexiblePush
        borderShape = .roundedRectangle
        showsBorderOnlyWhileMouseInside = false
        imagePosition = .imageLeading
        imageHugsTitle = true
        alignment = .natural
        usesSingleLineMode = false
        lineBreakMode = .byCharWrapping
        cell?.wraps = true
        cell?.truncatesLastVisibleLine = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth).isActive = true
        widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumWidth).isActive = true
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }
}

@MainActor
final class NativeWrappingPopUpButtonCell: NSPopUpButtonCell {
    override func cellSize(forBounds rect: NSRect) -> NSSize {
        let natural = super.cellSize(forBounds: rect)
        let titleFrame = super.titleRect(forBounds: NSRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: natural.height
        ))
        let titleHeight = measuredTitleHeight(for: titleFrame.width)
        let verticalInsets = max(0, natural.height - titleFrame.height)
        return NSSize(
            width: natural.width,
            height: max(natural.height, ceil(titleHeight + verticalInsets))
        )
    }

    override func titleRect(forBounds cellFrame: NSRect) -> NSRect {
        var titleFrame = super.titleRect(forBounds: cellFrame)
        let titleHeight = min(measuredTitleHeight(for: titleFrame.width), cellFrame.height)
        titleFrame.origin.y = cellFrame.midY - titleHeight / 2
        titleFrame.size.height = titleHeight
        return titleFrame
    }

    private func measuredTitleHeight(for width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return ceil(attributedTitle.boundingRect(
            with: NSSize(width: width, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height)
    }
}
