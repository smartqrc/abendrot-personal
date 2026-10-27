import Foundation
import CoreGraphics
import Logging
#if canImport(AppKit)
import AppKit
#endif

// MARK: - FullscreenGeometry

/// The pure geometry predicate behind the fullscreen check: no actor isolation, no AppKit, no window
/// access — just two rects. Kept separate so it is directly unit-testable.
public enum FullscreenGeometry {
    /// How far a window's rect may differ from a display's bounds and still count as covering it.
    /// CoreGraphics reports exact equality for native fullscreen; the tolerance absorbs rounding on
    /// mixed-DPI and scaled layouts.
    public static let coverTolerance: CGFloat = 3

    /// Whether `window` covers `display` within `tolerance` on every edge.
    ///
    /// This is what separates a fullscreen window from a merely zoomed one: macOS leaves the menu bar
    /// visible for ordinary windows, so their rect always starts below the display's top edge.
    public static func covers(
        _ window: CGRect,
        _ display: CGRect,
        tolerance: CGFloat = FullscreenGeometry.coverTolerance
    ) -> Bool {
        abs(window.minX - display.minX) <= tolerance
            && abs(window.minY - display.minY) <= tolerance
            && abs(window.width - display.width) <= tolerance
            && abs(window.height - display.height) <= tolerance
    }
}

// MARK: - FullscreenMonitor

/// Observes **fullscreen** state and tells the engine which displays to neutralise, so watching a
/// video (or playing a game) full-screen is shown in true colour and warmth returns the instant the
/// fullscreen window goes away.
///
/// This is the third suspend reason next to hold-to-reveal and per-app exclusion, and it composes with
/// both: it only reports *which* displays are covered edge to edge, never touching the user's warmth,
/// schedule, or any preference — so there is nothing to restore and nothing to persist.
///
/// **Detection is permission-free, by geometry only.** A window that covers its display *including the
/// menu-bar strip* is a fullscreen window; ordinary windows never can, because macOS always leaves the
/// menu bar visible for them. The inputs are `CGWindowListCopyWindowInfo` window *metadata* —
/// `kCGWindowOwnerPID`, `kCGWindowLayer`, `kCGWindowBounds` — plus `CGDisplayBounds`. Only the window
/// *title* (`kCGWindowName`) and pixel *capture* are gated by Screen Recording, and neither is read
/// here. No Accessibility either. This preserves the app's "No Screen Recording / No Accessibility"
/// privacy promise.
///
/// **Why a poll as well as notifications:** a native fullscreen window activates a new Space
/// (`activeSpaceDidChangeNotification`), but HTML5 video fullscreen and exclusive-fullscreen games do
/// not, so a low-frequency geometry rescan backs the notifications up. The scan is a handful of window
/// dictionaries and a per-display rect comparison, and the result is change-gated, so a steady state
/// costs one comparison per tick and never reaches the engine.
@MainActor
public final class FullscreenMonitor {
    private let engine: WarmthEngine
    /// Backstop cadence for fullscreen transitions that post no notification. Cheap enough at 0.4s;
    /// the engine is only touched when the display set actually changes.
    private let pollInterval: TimeInterval
    private let logger = Logger(label: "com.abendrot.WarmthKit.FullscreenMonitor")

    /// Windows owned by these are skipped: they routinely cover a whole display without the user
    /// being in a fullscreen app (the Finder desktop window covers the screen and would otherwise
    /// pin every display to true colour).
    private static let ignoredBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.wallpaper.agent",
    ]

    #if canImport(AppKit)
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    #endif

    private var isRunning = false

    /// The last set handed to the engine, so an unchanged scan is a pure no-op. `nil` forces the next
    /// scan to report (used on start so a launch *while already fullscreen* neutralises immediately).
    private var reported: Set<CGDirectDisplayID>?

    public init(engine: WarmthEngine, pollInterval: TimeInterval = 0.4) {
        self.engine = engine
        self.pollInterval = pollInterval
    }

    // MARK: - Lifecycle

    /// Begin observing. Idempotent. Seeds one scan immediately so a fullscreen app that is already up
    /// (or a display arrangement that changed while we were stopped) is reflected without waiting for
    /// the first tick.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        reported = nil
        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter
        // Native fullscreen always creates a Space; activation catches app switches into an
        // already-fullscreen window.
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // `queue: .main` guarantees main-thread delivery; hop onto the actor for the scan.
                Task { @MainActor in self?.rescan() }
            }
            observers.append(token)
        }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rescan() }
        }
        // `.common` so the backstop keeps ticking while a menu or a drag is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        #endif
        rescan()
    }

    /// Stop observing and clear any suspend we had applied, so disabling the feature restores warmth
    /// immediately. Safe to call repeatedly.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        timer?.invalidate()
        timer = nil
        #endif
        reported = []
        let engine = self.engine
        Task { await engine.setFullscreenDisplays([]) }
    }

    // MARK: - Scan

    /// Recompute the fullscreen display set and forward it to the engine when it changed.
    private func rescan() {
        guard isRunning else { return }
        let ids = Self.fullscreenDisplays()
        guard ids != reported else { return }
        reported = ids
        if ids.isEmpty {
            logger.debug("fullscreen ended")
        } else {
            logger.debug("fullscreen on displays \(ids.sorted())")
        }
        let engine = self.engine
        Task { await engine.setFullscreenDisplays(ids) }
    }

    /// The displays currently covered edge to edge by an on-screen, layer-0 window of another process.
    ///
    /// `optionOnScreenOnly` restricts the list to the *current Space*, which is what makes "switch away
    /// from the fullscreen app" restore warmth for free: its window is no longer on screen.
    static func fullscreenDisplays() -> Set<CGDirectDisplayID> {
        let displays = activeDisplayBounds()
        guard !displays.isEmpty else { return [] }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: Set<CGDirectDisplayID> = []
        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            // Never ourselves: our own panels/overlays must not report themselves as fullscreen.
            guard ownerPID != ownPID else { continue }
            // Normal application windows are layer 0; skip panels, menus, and utility layers.
            guard (window[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  !rect.isEmpty else { continue }
            if let bundleID = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier,
               ignoredBundleIDs.contains(bundleID) {
                continue
            }
            for (displayID, displayRect) in displays where FullscreenGeometry.covers(rect, displayRect) {
                result.insert(displayID)
            }
        }
        return result
    }

    /// Bounds of every active display, in the same global top-left-origin CoreGraphics space that
    /// `kCGWindowBounds` reports in. Read fresh each scan (cheap, and always correct across rearranges).
    private static func activeDisplayBounds() -> [CGDirectDisplayID: CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [:] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [:] }
        var map: [CGDirectDisplayID: CGRect] = [:]
        for id in ids.prefix(Int(count)) {
            map[id] = CGDisplayBounds(id)
        }
        return map
    }
}
