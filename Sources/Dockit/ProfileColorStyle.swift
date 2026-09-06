import AppKit
import DockitCore
import SwiftUI

struct ProfileIdentityColor {
    let lightness: Double
    let chroma: Double
    let hue: Double

    var linearSRGB: (red: Double, green: Double, blue: Double) {
        let radians = hue * .pi / 180
        let a = chroma * cos(radians)
        let b = chroma * sin(radians)
        let lPrime = lightness + 0.396_337_777_4 * a + 0.215_803_757_3 * b
        let mPrime = lightness - 0.105_561_345_8 * a - 0.063_854_172_8 * b
        let sPrime = lightness - 0.089_484_177_5 * a - 1.291_485_548 * b
        let l = lPrime * lPrime * lPrime
        let m = mPrime * mPrime * mPrime
        let s = sPrime * sPrime * sPrime
        return (
            4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s,
            -1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s,
            -0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701 * s
        )
    }

    var sRGB: (red: Double, green: Double, blue: Double) {
        let linear = linearSRGB
        return (
            encode(linear.red),
            encode(linear.green),
            encode(linear.blue)
        )
    }

    var isInSRGBGamut: Bool {
        let rgb = linearSRGB
        return [rgb.red, rgb.green, rgb.blue].allSatisfy { 0...1 ~= $0 }
    }

    var color: Color {
        let rgb = sRGB
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private func encode(_ component: Double) -> Double {
        component <= 0.003_130_8
            ? 12.92 * component
            : 1.055 * pow(component, 1 / 2.4) - 0.055
    }
}

extension ProfileColor {
    var identityColor: ProfileIdentityColor {
        switch self {
        case .blue: ProfileIdentityColor(lightness: 0.643_726, chroma: 0.180_074, hue: 250.274_915)
        case .purple: ProfileIdentityColor(lightness: 0.534_386, chroma: 0.233_247, hue: 281.412_014)
        case .pink: ProfileIdentityColor(lightness: 0.700, chroma: 0.220_087, hue: 345)
        case .red: ProfileIdentityColor(lightness: 0.660, chroma: 0.203_817, hue: 25)
        case .orange: ProfileIdentityColor(lightness: 0.760, chroma: 0.156_846, hue: 60)
        case .yellow: ProfileIdentityColor(lightness: 0.850, chroma: 0.157_077, hue: 95)
        case .green: ProfileIdentityColor(lightness: 0.795_780, chroma: 0.215_412, hue: 146.094_992)
        case .teal: ProfileIdentityColor(lightness: 0.760, chroma: 0.118_112, hue: 190)
        case .gray: ProfileIdentityColor(lightness: 0.640, chroma: 0, hue: 0)
        }
    }

    var color: Color {
        identityColor.color
    }

    var darkIdentityColor: ProfileIdentityColor {
        let light = identityColor
        return ProfileIdentityColor(
            lightness: min(max(light.lightness, 0.62), 0.74),
            chroma: light.chroma * 0.85,
            hue: light.hue
        )
    }

    var title: String {
        rawValue
    }

    @MainActor var menuSwatchImage: NSImage {
        swatchImage(size: 10)
    }

    @MainActor var toolbarSwatchImage: NSImage {
        swatchImage(size: 14)
    }

    @MainActor func toolbarSwatchImage(for colorScheme: ColorScheme) -> NSImage {
        swatchImage(size: 14, colorScheme: colorScheme)
    }

    @MainActor private func swatchImage(size: CGFloat, colorScheme: ColorScheme? = nil) -> NSImage {
        let extent = NSSize(width: size + 2, height: size + 2)
        let scheme = colorScheme ?? (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .dark : .light)
        let renderer = ImageRenderer(content: ProfileColorSwatch(color: self, size: size)
            .padding(1)
            .environment(\.colorScheme, scheme))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(size: extent)
        image.size = extent
        image.isTemplate = false
        return image
    }
}

struct ProfileColorSwatch: View {
    let color: ProfileColor
    var size: CGFloat = 10
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: size * 2 / 7, style: .continuous)
            .fill(colorScheme == .dark ? color.darkIdentityColor.color : color.color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct ProfileIdentityBadge: View {
    let color: ProfileColor
    var size: CGFloat = 34
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 13 / 42, style: .continuous)
                .fill(colorScheme == .dark
                    ? Color.white.opacity(contrast == .increased ? 0.22 : 0.12)
                    : Color.white.opacity(0.8))
            ProfileColorSwatch(color: color, size: size * 10 / 17)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
