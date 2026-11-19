import AppKit
import SwiftUI
import XCTest
@testable import HarmonizerApp

/// The timeline reads and moves its horizontal scroll through the AppKit scroll
/// view behind SwiftUI's ScrollView, so it works on macOS 14.
@MainActor
final class TimelineScrollerTests: XCTestCase {
    private func scrollView(contentWidth: CGFloat = 5000) -> NSScrollView {
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        sv.hasHorizontalScroller = true
        sv.documentView = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 100))
        return sv
    }

    func testScrollingMovesTheViewAndIsReportedBack() {
        let sv = scrollView(), scroller = TimelineScroller()
        scroller.attach(sv)
        scroller.scroll(toX: 1200, animated: false)
        XCTAssertEqual(sv.contentView.bounds.origin.x, 1200)
        XCTAssertEqual(scroller.offsetX, 1200)
    }

    func testScrollsMadeElsewhereAreReported() {
        let sv = scrollView(), scroller = TimelineScroller()
        scroller.attach(sv)
        sv.contentView.scroll(to: NSPoint(x: 640, y: 0))
        XCTAssertEqual(scroller.offsetX, 640)
    }

    func testAttachingPicksUpTheCurrentOffset() {
        let sv = scrollView()
        sv.contentView.scroll(to: NSPoint(x: 300, y: 0))
        let scroller = TimelineScroller()
        scroller.attach(sv)
        XCTAssertEqual(scroller.offsetX, 300)
    }

    func testALiveScrollByTheUserIsStamped() {
        let sv = scrollView(), scroller = TimelineScroller()
        scroller.attach(sv)
        XCTAssertEqual(scroller.lastUserScroll, .distantPast)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: sv)
        XCTAssertLessThan(Date.now.timeIntervalSince(scroller.lastUserScroll), 1)
    }

    func testProgrammaticScrollsAreNotMistakenForTheUser() {
        let sv = scrollView(), scroller = TimelineScroller()
        scroller.attach(sv)
        scroller.scroll(toX: 900, animated: false)
        XCTAssertEqual(scroller.lastUserScroll, .distantPast)
    }

    /// The bridge relies on SwiftUI's ScrollView being an NSScrollView underneath.
    func testTheProbeFindsASwiftUIScrollView() {
        let scroller = TimelineScroller()
        let content = ScrollView(.horizontal) {
            Rectangle().frame(width: 5000, height: 100)
                .background { TimelineScrollProbe(scroller: scroller) }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }

        scroller.scroll(toX: 700, animated: false)
        XCTAssertEqual(scroller.offsetX, 700)
    }

    func testLettingGoOfAnOlderScrollViewKeepsTheCurrentOne() {
        let old = scrollView(), current = scrollView(), scroller = TimelineScroller()
        scroller.attach(old)
        scroller.attach(current)
        scroller.detach(from: old)
        scroller.scroll(toX: 400, animated: false)
        XCTAssertEqual(current.contentView.bounds.origin.x, 400)
        XCTAssertEqual(scroller.offsetX, 400)
    }

    func testWithoutAScrollViewScrollingDoesNothing() {
        let scroller = TimelineScroller()
        scroller.scroll(toX: 500, animated: false)
        XCTAssertEqual(scroller.offsetX, 0)
    }
}
