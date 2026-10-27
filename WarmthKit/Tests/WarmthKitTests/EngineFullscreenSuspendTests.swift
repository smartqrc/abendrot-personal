import Testing
import Foundation
import CoreGraphics
@testable import WarmthKit
@testable import HardwareDDC
@testable import WarmthCore

/// Fullscreen suspend: while a foreground fullscreen window covers a display, the engine neutralises
/// ONLY that display (true colour) and restores the schedule's warmth when the set goes empty. Driven
/// headlessly through `setFullscreenDisplays(_:)` and asserted via `appliedMethod` (`.off` ==
/// suspended, `.hardware` == the warm DDC layer), mirroring `EngineExclusionTests`' harness.
@Suite("Engine fullscreen suspend")
struct EngineFullscreenSuspendTests {

    /// Two DDC-warmed displays with distinct `CGDirectDisplayID`s, enabled, always-on, warmth > 0 —
    /// so each un-suspended display reads `appliedMethod == .hardware` and a suspended one reads `.off`.
    private func warmedTwoDisplayEngine(
        store: InMemoryDDCSnapshotStore, displays: [DisplayIdentity]
    ) async -> WarmthEngine {
        let engine = WarmthEngine.test(backends: [FaultInjectingBackend(method: .hardware)], store: store, displays: displays)
        await engine.start()
        for display in displays { await engine.setHardwareDDCEnabled(true, for: display) }
        await engine.setEnabled(true)
        await engine.setScheduleMode(.alwaysOn)
        for display in displays { await engine.setWarmth(WarmthLevel(strength: 0.8), for: display) }
        return engine
    }

    private func appliedMethod(_ engine: WarmthEngine, for id: DisplayIdentity) async -> DisplayMethod? {
        await engine.state.displays.first(where: { $0.id == id })?.appliedMethod
    }

    private func twoDisplays() -> (a: DisplayIdentity, b: DisplayIdentity) {
        (DisplayIdentity.fixture(cgUUID: UUID(), displayID: 1),
         DisplayIdentity.fixture(cgUUID: UUID(), displayID: 2))
    }

    @Test("Fullscreen on ONE display → only that display suspends, the other stays warm")
    func fullscreenOnOneDisplaySuspendsOnlyThatDisplay() async {
        let store = InMemoryDDCSnapshotStore()
        let (a, b) = twoDisplays()
        let engine = await warmedTwoDisplayEngine(store: store, displays: [a, b])

        #expect(await appliedMethod(engine, for: a) == .hardware)     // both warm to begin with
        #expect(await appliedMethod(engine, for: b) == .hardware)

        await engine.setFullscreenDisplays([1])                        // a video goes fullscreen on A

        #expect(await appliedMethod(engine, for: a) == .off)          // A returns to true colour
        #expect(await appliedMethod(engine, for: b) == .hardware)     // B keeps the schedule's warmth
    }

    @Test("Leaving fullscreen → the display returns to the schedule's warmth")
    func leavingFullscreenRestoresWarmth() async {
        let store = InMemoryDDCSnapshotStore()
        let (a, b) = twoDisplays()
        let engine = await warmedTwoDisplayEngine(store: store, displays: [a, b])

        await engine.setFullscreenDisplays([1])
        #expect(await appliedMethod(engine, for: a) == .off)

        await engine.setFullscreenDisplays([])                         // fullscreen window closed
        #expect(await appliedMethod(engine, for: a) == .hardware)      // warmed again, nothing to restore
        #expect(await appliedMethod(engine, for: b) == .hardware)
    }

    @Test("Suspend follows the fullscreen window across displays")
    func suspendFollowsFullscreenAcrossDisplays() async {
        let store = InMemoryDDCSnapshotStore()
        let (a, b) = twoDisplays()
        let engine = await warmedTwoDisplayEngine(store: store, displays: [a, b])

        await engine.setFullscreenDisplays([1])
        #expect(await appliedMethod(engine, for: a) == .off)

        await engine.setFullscreenDisplays([2])                        // user drags the video to display B
        #expect(await appliedMethod(engine, for: a) == .hardware)
        #expect(await appliedMethod(engine, for: b) == .off)
    }

    @Test("A fullscreen window spanning both displays suspends both")
    func fullscreenSpanningBothSuspendsBoth() async {
        let store = InMemoryDDCSnapshotStore()
        let (a, b) = twoDisplays()
        let engine = await warmedTwoDisplayEngine(store: store, displays: [a, b])

        await engine.setFullscreenDisplays([1, 2])

        #expect(await appliedMethod(engine, for: a) == .off)
        #expect(await appliedMethod(engine, for: b) == .off)
    }

    @Test("Composes with reveal: ending reveal must NOT warm up while still fullscreen")
    func composesWithReveal() async {
        let store = InMemoryDDCSnapshotStore()
        let (a, _) = twoDisplays()
        let engine = await warmedTwoDisplayEngine(store: store, displays: [a])

        await engine.setFullscreenDisplays([1])
        await engine.beginReveal()                                     // both suspend reasons active
        #expect(await appliedMethod(engine, for: a) == .off)

        await engine.endReveal()                                       // reveal ends, still fullscreen
        #expect(await appliedMethod(engine, for: a) == .off)            // STILL suspended — they compose
    }

    @Test("Composes with per-app exclusion: clearing fullscreen must NOT warm up an excluded app's display")
    func composesWithExclusion() async {
        let store = InMemoryDDCSnapshotStore()
        let (a, _) = twoDisplays()
        let engine = await warmedTwoDisplayEngine(store: store, displays: [a])

        await engine.setExcludedApps(["com.x"])
        await engine.setFrontmostApp("com.x", onDisplays: [1])
        await engine.setFullscreenDisplays([1])                        // excluded app also goes fullscreen
        #expect(await appliedMethod(engine, for: a) == .off)

        await engine.setFullscreenDisplays([])                          // fullscreen ends, exclusion remains
        #expect(await appliedMethod(engine, for: a) == .off)            // still suspended by the exclusion
    }

    @Test("Disabling warming while fullscreen stays neutral; clearing fullscreen leaves it neutral")
    func disabledWhileFullscreenStaysNeutral() async {
        let store = InMemoryDDCSnapshotStore()
        let (a, _) = twoDisplays()
        let engine = await warmedTwoDisplayEngine(store: store, displays: [a])

        await engine.setFullscreenDisplays([1])
        await engine.setEnabled(false)
        #expect(await appliedMethod(engine, for: a) == .off)

        await engine.setFullscreenDisplays([])                          // user disabled warming, so no warm-up
        #expect(await appliedMethod(engine, for: a) == .off)
    }

    // MARK: - Geometry predicate

    @Test("covers(): exact display coverage matches, a menu-bar-respecting window does not")
    func coverPredicate() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

        #expect(FullscreenGeometry.covers(display, display))                        // native fullscreen
        #expect(FullscreenGeometry.covers(display.offsetBy(dx: 1, dy: -1), display)) // sub-pixel drift
        // A zoomed/maximised ordinary window: starts below the menu bar, so it never covers the display.
        #expect(!FullscreenGeometry.covers(
            CGRect(x: 0, y: 37, width: 1512, height: 945), display
        ))
        // A window on the second display must not count as covering the first.
        #expect(!FullscreenGeometry.covers(
            CGRect(x: 1512, y: 0, width: 1512, height: 982), display
        ))
    }
}
