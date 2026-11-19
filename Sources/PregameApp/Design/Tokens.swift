import AppKit
import SwiftUI

/// Spacing steps. Ad-hoc values snap to the nearest step.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let xxxl: CGFloat = 32
}

/// Corner radii; draw them with `style: .continuous`. Pills use `Capsule`.
enum Radius {
    /// Cue flags, strip ticks.
    static let hair: CGFloat = 2
    /// Track blocks, chips, key pills.
    static let small: CGFloat = 4
    /// Buttons, lane headers, segments.
    static let medium: CGFloat = 6
    /// Cards, popovers, Energy Shape cards.
    static let large: CGFloat = 10
    /// Tonight artwork, the empty-state drop zone.
    static let xl: CGFloat = 16
}

/// Named animations. With Reduce Motion on, every spring and glide becomes a short
/// fade and looping animations stop.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private static let reducedFade = Animation.easeInOut(duration: 0.15)

    /// Hover reveals: lane shape menu, ⋯ menu, lock.
    static var hover: Animation { reduced ? reducedFade : .easeOut(duration: 0.15) }
    /// Pills and chips under the pointer, star toggle, Match morph after Fix.
    static var pop: Animation { reduced ? reducedFade : .spring(response: 0.25, dampingFraction: 0.7) }
    /// Preset and chip value changes, segmented controls.
    static var snap: Animation { reduced ? reducedFade : .spring(response: 0.3, dampingFraction: 0.8) }
    /// List reorder, Pool moves, Bridge Track insert, expand/collapse.
    static var settle: Animation { reduced ? reducedFade : .spring(response: 0.35, dampingFraction: 0.85) }
    /// The editor sliding to the next Transition, timeline follow-scroll.
    static var glide: Animation { reduced ? reducedFade : .smooth(duration: 0.45) }
    /// Content swaps, loading → ready, sheet step changes.
    static var fade: Animation { .easeInOut(duration: 0.2) }
    /// Analysing dot, now-playing pulse. Nil (no loop) with Reduce Motion.
    static var breathe: Animation? { reduced ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true) }
}
