import SwiftUI

/// Motion tokens and the transitions built from them.
/// Values follow transitions.dev (commit 2773886); see `.claude/skills/knarr-motion/SKILL.md`.
/// Pick a token by what the motion does, not by how close the number is.
enum Motion {
    // Durations, seconds.
    static let stagger = 0.04
    static let micro = 0.08
    static let quick = 0.15
    static let fast = 0.25
    static let resize = 0.3
    static let medium = 0.35
    static let slow = 0.4
    static let verySlow = 0.5
    static let shimmer = 2.0
    /// Only the active assistant row requests reveal frames; the schedule pauses when settled.
    static let streamingFrame = 1.0 / 60

    // Distances, points.
    static let distanceMicro: CGFloat = 4
    static let distanceBase: CGFloat = 8
    static let distanceMedium: CGFloat = 12
    static let panelTravel: CGFloat = 96

    // Blur radii, points.
    static let blurSmall: CGFloat = 2
    static let blurMedium: CGFloat = 3

    static func smoothOut(_ duration: Double) -> Animation { .timingCurve(0.22, 1, 0.36, 1, duration: duration) }

    // Animations by usage.
    static let panelOpen = smoothOut(slow)
    static let panelClose = smoothOut(medium)
    static let popOpen = smoothOut(fast)
    static let popClose = smoothOut(quick)
    static let disclosure = smoothOut(fast)
    static let layout = smoothOut(resize)
    static let textSwap = Animation.easeInOut(duration: quick)
    static let iconSwap = Animation.easeInOut(duration: fast)
    static let numberPop = Animation.timingCurve(0.34, 1.45, 0.64, 1, duration: verySlow)
}

/// Offset, scale, and blur that drop away under Reduce Motion, leaving only the fade.
struct MotionShift: ViewModifier {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var scale: CGFloat = 1
    var blur: CGFloat = 0
    var opacity: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : scale)
            .blur(radius: reduceMotion ? 0 : blur)
            .offset(x: reduceMotion ? 0 : x, y: reduceMotion ? 0 : y)
            .opacity(opacity)
    }
}

extension AnyTransition {
    private static func shift(_ active: MotionShift) -> AnyTransition { .modifier(active: active, identity: MotionShift()) }

    /// Text states swap: the old line leaves upward through a small blur while the new one rises in.
    /// Give the text `.id(value)` inside a container that animates on that value.
    static var textSwap: AnyTransition { swap(distance: Motion.distanceMicro) }
    static func swap(distance: CGFloat) -> AnyTransition {
        .asymmetric(insertion: shift(.init(y: distance, blur: Motion.blurSmall, opacity: 0)),
                    removal: shift(.init(y: -distance, blur: Motion.blurSmall, opacity: 0)))
    }

    /// Icon swap: two icons share a slot, the new one grows in from a quarter size.
    static var iconSwap: AnyTransition { shift(.init(scale: 0.25, blur: Motion.blurSmall, opacity: 0)) }

    /// Accordion body and skeleton reveal: fade through a small blur in place.
    static var softReveal: AnyTransition { shift(.init(blur: Motion.blurSmall, opacity: 0)) }

    /// Dropdown-sized surfaces: grow from 97%, shrink only to 99% on the way out.
    static var pop: AnyTransition {
        .asymmetric(insertion: shift(.init(scale: 0.97, opacity: 0)), removal: shift(.init(scale: 0.99, opacity: 0)))
    }

    /// Panel reveal from the trailing edge: a short travel plus fade and blur reads as a full open.
    static var trailingPanel: AnyTransition { shift(.init(x: Motion.panelTravel, blur: Motion.blurSmall, opacity: 0)) }
}

/// Muted text with a highlight band sweeping across it, for status lines that should feel alive.
/// Only shown while work runs; the sweep is a SwiftUI animation, so keep it off idle screens.
struct ShimmerText: View {
    let text: String
    var font: Font = K.secondary.weight(.medium)
    @State private var sweeping = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text).font(font).foregroundStyle(K.faint)
            .overlay {
                if !reduceMotion {
                    Text(text).font(font).foregroundStyle(K.ink)
                        .mask {
                            GeometryReader { g in
                                LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: K.ink, location: 0.5), .init(color: .clear, location: 0.6)],
                                               startPoint: .leading, endPoint: .trailing)
                                    .frame(width: g.size.width * 4)
                                    .offset(x: sweeping ? 0 : -g.size.width * 3)
                            }
                        }
                        .onAppear {
                            withAnimation(.linear(duration: Motion.shimmer).repeatForever(autoreverses: false)) { sweeping = true }
                        }
                }
            }
    }
}
