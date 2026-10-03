import CoreText
import SwiftUI

/// The same bundled Inter body and Sora display faces used by Rally TV.
public enum RallyFont {
    private static func register(_ resource: String) -> String {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "ttf", subdirectory: "Resources") else { return "HelveticaNeue" }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { return "HelveticaNeue" }
        return name
    }
    private static let bodyName = register("inter_variable")
    private static let displayName = register("sora_variable")
    public static func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let font = Font.custom(bodyName, size: size).weight(weight)
        return design == .monospaced ? font.monospaced() : font
    }
    public static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom(displayName, size: size).weight(weight)
    }
}
