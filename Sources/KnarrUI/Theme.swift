import AppKit
import SwiftUI
import KnarrCore

/// Design tokens. The rules behind them live in `.claude/skills/knarr-design/SKILL.md`.
/// Screens use these and nothing else: no `.system(size:)`, hex, `Color(red:)` or corner number outside this file
/// (`DesignTokenTests` fails the build of the suite when one appears).
enum K {
    /// App artwork in the navigation rail.
    static let brandMark: CGFloat = 34
    /// Auxiliary message conversations stay readable beside the main window.
    static let conversationWindowSize = NSSize(width: 560, height: 640)
    static let conversationWindowMinimumSize = NSSize(width: 380, height: 320)
    // MARK: Color. Neutral by default; color only for meaning, and small (a dot, an icon, a 2pt bar, text).

    /// One calm blue: selection, links, focus, and "Hird is working". Never a background wash.
    static let accent = dyn(0x2F6FEB, 0x6EA1FF)
    static let accentSoft = dyn(0xE8EFFD, 0x1C2A45)
    static let nsAccent = nsDyn(0x2F6FEB, 0x6EA1FF)

    static let canvas = dyn(0xFAFAFB, 0x1A1A1D)
    static let surface = dyn(0xFFFFFF, 0x222226)
    static let sunken = dyn(0xF4F4F6, 0x2A2A2F)
    static let line = dyn(0x000000, 0xFFFFFF, alpha: 0.07)
    static let lineStrong = dyn(0x000000, 0xFFFFFF, alpha: 0.14)

    static let ink = dyn(0x26262B, 0xECECEF)
    /// Text on an `ink` fill: the primary button and the send circle. Flips with the mode so contrast holds.
    static let onInk = dyn(0xFFFFFF, 0x1A1A1D)
    static let muted = dyn(0x5C5C65, 0xB2B2BA)
    static let faint = dyn(0x777780, 0x8E8E97)

    /// Errors, destructive actions, STOP, a stopped Hird. Nothing else is red.
    static let red = dyn(0xC42B1C, 0xF0786C)
    static let redSoft = dyn(0xFCEDEB, 0x3A2321)
    /// Something waits on the person: an approval, an answer, a check.
    static let amber = dyn(0x96560A, 0xE7A853)
    static let nsAmber = nsDyn(0x96560A, 0xE7A853)
    static let amberSoft = dyn(0xFBF1E4, 0x382B1B)
    static let green = dyn(0x217A4F, 0x6CCB97)
    static let greenSoft = dyn(0xE7F4EC, 0x1C3127)

    static let codeChip = dyn(0xEFEFF3, 0x34343A)
    static let synKeyword = dyn(0x8E3FB0, 0xD39BF0)
    static let synString = dyn(0x2F7A3A, 0x8FD19E)
    static let synNumber = dyn(0xB0560E, 0xF2A766)

    /// The Knarr mark in the rail. The only brand color in the app.
    static let brand = dyn(0x1F3A5F, 0x3B5F8F)
    /// White letters on a project's color fill, in both modes.
    static let onColor = Color(white: 1)
    /// The menu-bar label is a template image; macOS tints black to match the bar.
    static let templateInk = Color(white: 0)
    /// Only floating things cast a shadow: the jump-to-latest button and popovers.
    static let shadow = dyn(0x000000, 0x000000, alpha: 0.14)

    /// Project icon fills; `onColor` sits on every one in both modes.
    static let projectColors: [Color] = [
        dyn(0x1F3A5F, 0x3B5F8F), dyn(0xC9363A, 0xC9363A), dyn(0x217A4F, 0x2E8A5C), dyn(0x96560A, 0xA8650F),
        dyn(0x8E3FB0, 0x9A4FC0), dyn(0x1C61D4, 0x2F6FD8), dyn(0x5E5B68, 0x6A6774),
    ]
    static func projectColor(_ index: Int) -> Color { projectColors[((index % projectColors.count) + projectColors.count) % projectColors.count] }

    // MARK: Type. Five steps; weights are regular, medium or semibold only.

    static let title = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13.5)
    static let secondary = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let mono = Font.system(size: 12, design: .monospaced)
    /// The rail's icons. Every other symbol is sized by the text step it sits beside.
    static let railIcon = Font.system(size: 16)
    /// Extra space between lines of chat body text, for a line height of about 1.45 × the size.
    static let bodyLineSpacing: CGFloat = 3.5

    static var nsBody: NSFont { NSFont.systemFont(ofSize: 13.5) }
    static var nsCaptionDigits: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) }

    // MARK: Space on a 4pt grid, corners, and the few fixed sizes.

    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24
    static let s6: CGFloat = 32

    /// Chips, inputs, badges.
    static let rSmall: CGFloat = 6
    /// Cards, code, tables, message bubbles.
    static let rCard: CGFloat = 10
    /// The composer.
    static let rLarge: CGFloat = 14

    static let column: CGFloat = 740
    static let drawerWidth: CGFloat = 560
    /// The navigation rail's fixed width. It is not part of the conversation area.
    static let railWidth: CGFloat = 64

    /// The issue detail beside the conversation: a 380pt floor, a 560pt default, at most 60% of the
    /// content width, and a conversation that never falls below 480pt. The splitter hit area is 24pt.
    static let issuePanelMinimumWidth: CGFloat = 380
    static let issuePanelDefaultWidth: CGFloat = 560
    static let issuePanelMaximumFraction: CGFloat = 0.6
    static let issueConversationMinimumWidth: CGFloat = 480
    static let issueResizeHitWidth: CGFloat = 24
    static let issueResizeLineWidth: CGFloat = 1
    static let issueResizeGripWidth: CGFloat = 3
    static let issueResizeGripHeight: CGFloat = 32
    static let issueResizeGuideWidth: CGFloat = 2
    static let issueResizeKeyboardStep: CGFloat = 24
    static let badgeHeight: CGFloat = 18
    static let chipHeight: CGFloat = 22
    static let controlHeight: CGFloat = 24
    static let sendButton: CGFloat = 28
    static let headerHeight: CGFloat = 48
    static let dot: CGFloat = 6
    static let bar: CGFloat = 3
    static let avatar: CGFloat = 24
    static let boardBar: CGFloat = 64
    /// Browser tabs truncate titles without crowding their close controls.
    static let tabTitleWidth: CGFloat = 180
    /// Fixed slot beside a tab title so an arriving count never moves the title or its neighbours.
    static let tabBadgeWidth: CGFloat = 22
    static let tabUnderline: CGFloat = 2

    /// Project navigation, detail column, and the accessible conversation splitter.
    static let projectListWidth: CGFloat = 248
    static let projectDetailMinimumWidth: CGFloat = 480
    /// Document navigation uses a compact list above the reader in narrow project panels.
    static let preparationOverviewMaximumWidth: CGFloat = 1120
    static let preparationTableMinimumWidth: CGFloat = 620
    static let preparationOrganizationWidth: CGFloat = 132
    static let preparationDeadlineWidth: CGFloat = 116
    static let preparationEditorWidth: CGFloat = 640
    static let preparationEditorHeight: CGFloat = 640
    static let preparationTextEditorHeight: CGFloat = 192
    static let documentCompactListHeight: CGFloat = 192
    static let projectCollapsedPanelWidth = headerHeight
    static let projectResizeHitWidth: CGFloat = 24
    static let projectResizeLineWidth: CGFloat = 1
    static let projectResizeGripWidth: CGFloat = 3
    static let projectResizeGripHeight: CGFloat = 32
    static let projectResizeGuideWidth: CGFloat = 2
    static let projectResizeKeyboardStep: CGFloat = 24
    static func projectPanelWidth(_ policy: ProjectSessionPolicy, preferred: Double) -> CGFloat {
        let width = preferred.isFinite && preferred > 0 ? preferred : policy.panelDefaultWidth
        return CGFloat(max(width, policy.panelMinimumWidth))
    }
    static func projectPanelMinimumWidth(_ policy: ProjectSessionPolicy) -> CGFloat {
        CGFloat(policy.panelMinimumWidth)
    }

    private static func dyn(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: nsDyn(light, dark, alpha: alpha))
    }

    private static func nsDyn(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
    }
}

extension View {
    /// A floating element's shadow; the only one the app uses.
    func floatingShadow() -> some View { shadow(color: K.shadow, radius: 6, y: 2) }
}

extension IssueStatus {

    /// Text and dot in `fg`, a very light wash in `bg`.
    var tint: (fg: Color, bg: Color) {
        switch self {
        case .awaitingApproval, .cancelled: (K.muted, K.sunken)
        case .inProgress: (K.accent, K.accentSoft)
        case .needsAnswer, .judging, .awaitingIntegration: (K.amber, K.amberSoft)
        case .unmet, .failed: (K.red, K.redSoft)
        case .completed: (K.green, K.greenSoft)
        }
    }
}

extension HirdStep.State {
    var mark: String {
        switch self {
        case .done: "✓"
        case .active: "●"
        case .pending: ""
        case .waiting: "…"
        case .blocked: "!"
        case .failed: "×"
        }
    }

    /// (label text, bar segment)
    var colors: (fg: Color, bar: Color) {
        switch self {
        case .done: (K.green, K.green)
        case .active: (K.accent, K.accent)
        case .pending: (K.faint, K.lineStrong)
        case .waiting: (K.faint, K.faint)
        case .blocked: (K.amber, K.amber)
        case .failed: (K.red, K.red)
        }
    }
}

// The web transcript consumes the same tokens as the surrounding native screens.
extension K {
    /// Rasterize the system's SF Symbols once; CSS masks inherit the current token color.
    @MainActor private static let webActionSymbols: [String: String] = {
        var result: [String: String] = [:]
        for (token, name) in ["symbolCopy": "doc.on.doc", "symbolEdit": "pencil", "symbolCheck": "checkmark",
                              "symbolBubble": "text.bubble", "symbolCollapse": "chevron.down",
                              "symbolExpandWindow": "arrow.up.right.square", "symbolClose": "xmark",
                              "symbolSend": "arrow.up", "symbolStop": "stop.fill"] {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)),
                  let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            result[token] = "url('data:image/png;base64,\(png.base64EncodedString())')"
        }
        return result
    }()
    @MainActor static func webTokens(dark: Bool) -> [String: String] {
        var result: [String: String] = [:]
        let colors: [String: Color] = ["ink": ink, "muted": muted, "faint": faint, "surface": surface,
            "sunken": sunken, "line": line, "lineStrong": lineStrong, "accent": accent, "accentSoft": accentSoft,
            "red": red, "amber": amber, "green": green, "onInk": onInk, "codeChip": codeChip,
            "synKeyword": synKeyword, "synString": synString, "synNumber": synNumber]
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            for (key, value) in colors {
                if let c = NSColor(value).usingColorSpace(.sRGB) {
                    result[key] = "rgba(\(Int(c.redComponent * 255)),\(Int(c.greenComponent * 255)),\(Int(c.blueComponent * 255)),\(c.alphaComponent))"
                }
            }
        }
        for (name, value) in ["s1": s1, "s2": s2, "s3": s3, "s4": s4, "s5": s5, "s6": s6,
                              "rSmall": rSmall, "rCard": rCard, "rLarge": rLarge,
                              "column": column, "controlHeight": controlHeight,
                              "body": nsBody.pointSize, "caption": nsCaptionDigits.pointSize,
                              "secondary": CGFloat(12), "title": CGFloat(15)] { result[name] = "\(value)px" }
        result.merge(webActionSymbols) { _, symbol in symbol }
        return result
    }
}
