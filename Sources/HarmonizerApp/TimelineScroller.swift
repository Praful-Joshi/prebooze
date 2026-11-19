import AppKit
import SwiftUI

/// The timeline's horizontal scroll: where it is, when the user last scrolled
/// it, and a way to move it. Works through the AppKit scroll view behind
/// SwiftUI's ScrollView, because ScrollPosition and the scroll-geometry
/// modifiers need macOS 15 and Prebooze supports macOS 14.
@MainActor
final class TimelineScroller {
    /// The left edge of the visible area, in content points.
    private(set) var offsetX: CGFloat = 0
    /// When the user last scrolled by hand (wheel, trackpad or scroller).
    private(set) var lastUserScroll = Date.distantPast
    private weak var scrollView: NSScrollView?
    private var wheelMonitor: Any?

    func attach(_ sv: NSScrollView) {
        guard sv !== scrollView else { return }
        detach()
        scrollView = sv
        let clip = sv.contentView
        clip.postsBoundsChangedNotifications = true
        offsetX = clip.bounds.origin.x
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: clip)
        nc.addObserver(self, selector: #selector(userScrolled), name: NSScrollView.willStartLiveScrollNotification, object: sv)
        nc.addObserver(self, selector: #selector(userScrolled), name: NSScrollView.didLiveScrollNotification, object: sv)
        // A mouse wheel scrolls without a live-scroll session, so watch for it too.
        // ⌘-scroll zooms (ScrollZoomCatcher) and is not a scroll.
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            MainActor.assumeIsolated {
                if let self, let sv = self.scrollView, e.window == sv.window, !e.modifierFlags.contains(.command),
                   sv.bounds.contains(sv.convert(e.locationInWindow, from: nil)) {
                    self.lastUserScroll = .now
                }
            }
            return e
        }
    }

    /// Lets go of `sv`, or of whatever scroll view is attached when `sv` is nil.
    /// A probe going away never detaches a scroll view a newer probe attached.
    func detach(from sv: NSScrollView? = nil) {
        guard sv == nil || sv === scrollView else { return }
        NotificationCenter.default.removeObserver(self)
        if let m = wheelMonitor { NSEvent.removeMonitor(m) }
        wheelMonitor = nil
        scrollView = nil
    }

    /// Moves the left edge of the visible area to `x`, with the `glide` motion
    /// (a jump with Reduce Motion on, or when `animated` is false).
    func scroll(toX x: CGFloat, animated: Bool = true) {
        guard let sv = scrollView else { return }
        let clip = sv.contentView
        let origin = NSPoint(x: x, y: clip.bounds.origin.y)
        if animated, let glide = Motion.glideAppKit {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = glide.duration
                ctx.timingFunction = glide.timing
                clip.animator().setBoundsOrigin(origin)
            } completionHandler: {
                sv.reflectScrolledClipView(clip)
            }
        } else {
            clip.setBoundsOrigin(origin)
            sv.reflectScrolledClipView(clip)
        }
    }

    @objc private func boundsChanged() {
        if let sv = scrollView { offsetX = sv.contentView.bounds.origin.x }
    }

    @objc private func userScrolled() { lastUserScroll = .now }
}

/// Placed inside a ScrollView's content, hands the AppKit scroll view behind it
/// to a TimelineScroller.
struct TimelineScrollProbe: NSViewRepresentable {
    let scroller: TimelineScroller

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.scroller = scroller
        return v
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.scroller = scroller
        nsView.attach()
    }

    static func dismantleNSView(_ nsView: Probe, coordinator: ()) {
        if let sv = nsView.attached { nsView.scroller?.detach(from: sv) }
    }

    final class Probe: NSView {
        var scroller: TimelineScroller?
        private(set) weak var attached: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        func attach() {
            if let sv = enclosingScrollView {
                scroller?.attach(sv)
                attached = sv
            }
        }

        // Never takes clicks or hovers meant for the timeline.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
