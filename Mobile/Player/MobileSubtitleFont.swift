import CoreText
import Foundation
import UIKit

/// The subtitle font, shipped with the app because the system's is
/// unreachable.
///
/// **Why this file exists, measured rather than guessed.** libass on iOS uses
/// the CoreText font provider, and mpv's default `sub-font` of `sans-serif`
/// resolves to Helvetica, which has no CJK at all. Every missing glyph then
/// goes to CoreText for a fallback, and CoreText answers with PingFang — at
/// `/System/Library/PrivateFrameworks/FontServices.framework/CorePrivate/
/// PingFangUI.ttc`, which a sandboxed app cannot open. The log says so
/// outright:
///
///     fontselect: (sans-serif, 400, 0) -> …/Helvetica.ttc
///     Glyph 0x8FD8 not found, selecting one more font
///     Error opening font: '…/CorePrivate/PingFangUI.ttc', 0
///     fontselect: failed to find any fallback with glyph 0x8FD8
///
/// What survived was whatever Hiragino Sans happened to cover, which is why
/// the symptom was so confusing: Japanese-shared kanji rendered and
/// simplified-only characters did not — 你 fine, 还 and 请 and 伤 not. And it
/// is why naming PingFang in `sub-font` made *everything* a box: CoreText
/// resolved the name to the same unreadable file, so even Helvetica was gone.
///
/// The only fix is a font the process can actually open. This one is
/// registered for the process at launch, so CoreText hands libass a URL
/// inside our own bundle. Noto Sans CJK SC covers simplified, traditional,
/// Japanese and Korean in one file, which retires the whole class of bug
/// rather than the half of it that showed up first — a `[CHT]` release would
/// have reproduced it exactly with a simplified-only subset.
@MainActor
enum MobileSubtitleFont {
    /// The `name` table's family (ID 1), which is what CoreText matches on.
    static let familyName = "Noto Sans CJK SC"
    private static let resource = "NotoSansCJKsc-Regular"

    /// Whether the font is registered *and* resolves. Only then is mpv told
    /// to use it: naming a font CoreText cannot produce is precisely how
    /// every glyph became a box once already.
    private(set) static var isAvailable = false

    static func register() {
        guard !isAvailable else { return }
        guard let url = Bundle.main.url(forResource: resource, withExtension: "otf") else { return }
        var error: Unmanaged<CFError>?
        // Process scope: the font is ours for this launch and is never added
        // to the user's system.
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            // Already registered is not a failure worth reporting; anything
            // else leaves `isAvailable` false and mpv untouched, so subtitles
            // fall back to what they did before rather than breaking.
            error?.release()
        }
        isAvailable = resolves()
    }

    /// `CTFontCreateWithName` substitutes silently when a name is unknown, so
    /// asking for the font is not the same as getting it — the family of what
    /// comes back has to be compared.
    private static func resolves() -> Bool {
        let font = CTFontCreateWithName(familyName as CFString, 20, nil)
        let resolved = CTFontCopyFamilyName(font) as String
        return resolved == familyName
    }
}
