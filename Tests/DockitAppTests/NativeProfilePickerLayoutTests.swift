import AppKit
import DockitCore
import Testing
@testable import dockit

@MainActor
struct NativeProfilePickerLayoutTests {
    @Test
    func hostedEditorPickerSharesTrafficLightCenter() async throws {
        await Task.yield()
        func pickers(in view: NSView) -> [NativeProfilePopUpButton] {
            (view as? NativeProfilePopUpButton).map { [$0] }
                ?? view.subviews.flatMap { pickers(in: $0) }
        }
        let hostedPickers = NSApp.windows.flatMap { window in
            window.contentView?.superview.map { pickers(in: $0) } ?? []
        }
        let picker = try #require(hostedPickers.first)
        let window = try #require(picker.window)
        let pickerCenter = picker.convert(picker.bounds, to: nil).midY
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let light = try #require(window.standardWindowButton(kind))
            let trafficLightCenter = light.convert(light.bounds, to: nil).midY
            print("picker-alignment button=\(kind.rawValue) picker=\(pickerCenter) light=\(trafficLightCenter) delta=\(abs(pickerCenter - trafficLightCenter))")
            #expect(abs(pickerCenter - trafficLightCenter) <= 1,
                "picker center \(pickerCenter), traffic light \(kind.rawValue) center \(trafficLightCenter)")
        }
    }

    @Test(arguments: ["Reading", "current dock", String(repeating: "W", count: DockProfile.maximumNameLength)])
    func swatchAndTitleStayInsideTheBackingWithHorizontalPadding(_ name: String) throws {
        let button = NativeProfilePopUpButton(frame: .zero, pullsDown: false)
        button.setDisplayedItem(title: name, image: ProfileColor.blue.toolbarSwatchImage)
        button.setFrameSize(button.measuredSize())
        let cell = try #require(button.cell as? NSPopUpButtonCell)
        let imageRect = cell.imageRect(forBounds: button.bounds)
        let titleRect = cell.titleRect(forBounds: button.bounds)
        let backingBounds = button.bounds.insetBy(dx: -NativeProfilePopUpButton.backingHorizontalInset, dy: 0)
        let paddedBounds = backingBounds.insetBy(dx: 8, dy: 0)

        #expect(imageRect.width > 0)
        #expect(button.bounds.contains(imageRect))
        #expect(button.bounds.contains(titleRect))
        #expect(paddedBounds.contains(imageRect), "name=\(name), backing=\(backingBounds), image=\(imageRect)")
        #expect(paddedBounds.contains(titleRect), "name=\(name), backing=\(backingBounds), title=\(titleRect)")
        #expect(imageRect.maxX <= titleRect.minX)
        #expect(titleRect.maxX <= button.bounds.maxX - 8)
        #expect(!button.pullsDown)
        #expect(cell.arrowPosition != .noArrow)
    }

    @Test
    func currentDockFitsBesideItsSwatchAndNativeArrows() throws {
        let button = NativeProfilePopUpButton(frame: .zero, pullsDown: false)
        let image = ProfileColor.blue.toolbarSwatchImage
        button.setDisplayedItem(title: "current dock", image: image)
        button.setFrameSize(button.measuredSize())
        let cell = try #require(button.cell as? NSPopUpButtonCell)
        let titleRect = cell.titleRect(forBounds: button.bounds)
        let titleSize = cell.attributedTitle.size()

        #expect(image.size == NSSize(width: 16, height: 16))
        #expect(button.displayedMenuItem?.image === image)
        #expect(!button.pullsDown)
        #expect(cell.arrowPosition != .noArrow)
        #expect(titleRect.minX > button.bounds.minX)
        #expect(titleRect.maxX < button.bounds.maxX)
        #expect(titleRect.width >= ceil(titleSize.width))
        #expect(titleRect.height >= ceil(titleSize.height))
        #expect(button.bounds.contains(titleRect))
        #expect(button.frame.height == 30)
    }

    @Test(arguments: ["current dock", "Current dock", "personal", "work"])
    func ordinaryNamesKeepTheirOneLineWidth(_ name: String) throws {
        let button = NativeProfilePopUpButton(frame: .zero, pullsDown: false)
        button.setDisplayedItem(title: name, image: ProfileColor.blue.toolbarSwatchImage)
        button.setFrameSize(button.measuredSize())
        let cell = try #require(button.cell as? NSPopUpButtonCell)
        let titleRect = cell.titleRect(forBounds: button.bounds)

        #expect(titleRect.width >= ceil(cell.attributedTitle.size().width))
        #expect(button.frame.width >= NativeProfilePopUpButton.minimumWidth)
        #expect(button.frame.width <= NativeProfilePopUpButton.maximumWidth)
        #expect(button.frame.height == 30)
        #expect(button.intrinsicContentSize == button.measuredSize())
    }

    @Test
    func wideNameWrapsWithoutExceedingItsTitleBounds() throws {
        let button = NativeProfilePopUpButton(frame: .zero, pullsDown: false)
        let name = String(repeating: "W", count: DockProfile.maximumNameLength)
        button.setDisplayedItem(title: name, image: ProfileColor.blue.toolbarSwatchImage)
        button.setFrameSize(button.measuredSize())
        let cell = try #require(button.cell as? NSPopUpButtonCell)
        let titleRect = cell.titleRect(forBounds: button.bounds)
        let textBounds = cell.attributedTitle.boundingRect(
            with: NSSize(width: titleRect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        #expect(button.frame.width == NativeProfilePopUpButton.maximumWidth)
        #expect(button.frame.height > 30)
        #expect(titleRect.width < cell.attributedTitle.size().width)
        #expect(titleRect.height >= ceil(textBounds.height))
        #expect(button.bounds.contains(titleRect))
        #expect(cell.attributedTitle.string == name)
        #expect(cell.wraps)
        #expect(!cell.truncatesLastVisibleLine)
        #expect(cell.arrowPosition != .noArrow)
    }

    @Test
    func returningToAnOrdinaryNameRestoresItsCompactSize() {
        let button = NativeProfilePopUpButton(frame: .zero, pullsDown: false)
        let image = ProfileColor.blue.toolbarSwatchImage
        button.setDisplayedItem(title: "current dock", image: image)
        let originalSize = button.measuredSize()
        button.setFrameSize(originalSize)
        button.setDisplayedItem(
            title: String(repeating: "W", count: DockProfile.maximumNameLength),
            image: image
        )
        button.setFrameSize(button.measuredSize())

        button.setDisplayedItem(title: "current dock", image: image)

        #expect(button.measuredSize() == originalSize)
    }
}
