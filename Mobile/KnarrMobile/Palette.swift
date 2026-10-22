import SwiftUI
import KnarrSync

/// Knarr's colors: a white workspace, quiet dividers, and a coral accent.
/// The mobile renderer receives these same light and dark tokens.
enum Palette {
    /// Coral is reserved for selection, progress and primary actions.
    static let accent = Color(light: 0xF04F52, dark: 0xFF7C7E)
    static let accentSoft = Color(light: 0xFFF0F0, dark: 0x3A2620)
    static let blue = Color(light: 0x3D5F8A, dark: 0x8FB0D8)
    static let red = Color(light: 0xA33A2B, dark: 0xE08C7E)
    static let amber = Color(light: 0x8A6420, dark: 0xDDB169)
    static let green = Color(light: 0x3B6B4B, dark: 0x8FBF9B)
    static let grey = Color(light: 0x77747F, dark: 0x8F8D98)
    /// Inline blocks inside a message: code, quotes and tables.
    static let sunken = Color(light: 0xFAFAFA, dark: 0x252525)

    // Page and surfaces.
    static let page = Color(light: 0xFFFFFF, dark: 0x191817)
    static let beige = Color(light: 0xFFFFFF, dark: 0x24211E)
    static let beigeDeep = Color(light: 0xFFF1F1, dark: 0x2E2A26)
    static let sidebar = Color(light: 0xFFFFFF, dark: 0x1E1C1A)
    static let card = Color(light: 0xFFFFFF, dark: 0x232120)

    // Text and lines.
    static let ink = Color(light: 0x252525, dark: 0xEDEAE5)
    static let muted = Color(light: 0x626262, dark: 0xB5B0A8)
    static let faint = Color(light: 0x767676, dark: 0x8C877F)
    static let line = Color(light: 0xE9E9E9, dark: 0x332F2B)
    static let lineStrong = Color(light: 0xDADADA, dark: 0x413B35)
    static let codeInk = Color(light: 0x9A3B16, dark: 0xF0A57A)
    static let codeChip = Color(light: 0xF6F6F6, dark: 0x2C2926)
    static let codeBlock = Color(light: 0xFFFFFF, dark: 0x1F1D1B)
    static let synKeyword = Color(light: 0x8E3FB0, dark: 0xD39BF0)
    static let synString = Color(light: 0x2F7A3A, dark: 0x8FD19E)
    static let synNumber = Color(light: 0xB0560E, dark: 0xF2A766)
    static let blueSoft = Color(light: 0xE9EEF5, dark: 0x212934)
    static let greenSoft = Color(light: 0xE8F1E9, dark: 0x20302A)
    static let redSoft = Color(light: 0xFAEAE6, dark: 0x352220)
    static let amberSoft = Color(light: 0xFAF0E0, dark: 0x33291C)

    static func color(_ state: MobileIssue.State) -> Color {
        switch state {
        case .running: accent
        case .needsInput: accent
        case .failed: red
        case .done: green
        case .awaitingApproval: accent
        case .rejected: red
        }
    }

    static func symbol(_ state: MobileIssue.State) -> String {
        switch state {
        case .running: "circle.dotted"
        case .needsInput: "hand.raised.fill"
        case .failed: "exclamationmark.octagon.fill"
        case .done: "checkmark.circle.fill"
        case .awaitingApproval: "hand.raised.fill"
        case .rejected: "xmark.circle.fill"
        }
    }

    static func label(_ state: MobileIssue.State) -> String {
        switch state {
        case .running: "진행 중"
        case .needsInput: "답변 필요"
        case .failed: "멈춤"
        case .done: "완료"
        case .awaitingApproval: "승인 대기"
        case .rejected: "거절됨"
        }
    }

    static func color(_ bucket: MobileDashboard.Bucket) -> Color {
        switch bucket {
        case .needsAnswer: amber
        case .awaitingApproval: muted
        case .judging: blue
        case .awaitingIntegration: blue
        case .unmet: red
        case .failed: red
        case .running: accent
        case .recentlyDone: green
        }
    }

    static func symbol(_ bucket: MobileDashboard.Bucket) -> String {
        switch bucket {
        case .needsAnswer: "questionmark.bubble.fill"
        case .awaitingApproval: "tray.full"
        case .judging: "hourglass"
        case .awaitingIntegration: "arrow.triangle.merge"
        case .unmet: "exclamationmark.triangle.fill"
        case .failed: "exclamationmark.octagon.fill"
        case .running: "circle.dotted"
        case .recentlyDone: "checkmark.circle.fill"
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
