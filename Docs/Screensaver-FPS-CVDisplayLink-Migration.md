# Screensaver FPS Fix: Migrate to CVDisplayLink

## Problem

`FruitScreensaver` renders at roughly **1/3 the frame rate** of the same animation
running inside `PreferencesViewController`. Both views render the identical
`FruitView` content, so the bottleneck is not the drawing code — it is **how each
view drives its animation loop**.

## Root Cause

### FruitScreensaver — NSTimer-based (slow path)

`FruitScreensaver` extends `ScreenSaverView` and relies on the framework's
built-in animation timer:

```swift
animationTimeInterval = 1.0 / 60.0   // requested 60 fps
```

The ScreenSaver engine calls `animateOneFrame()` from an internal `NSTimer`.
This timer:

- Is **not synchronized** with the display's vertical sync (vsync).
- Is subject to run-loop scheduling delays and macOS system-level throttling.
- Caps at a theoretical maximum of 60 fps regardless of display capability.
- In practice fires at roughly **20–40 fps** on modern macOS, because the
  ScreenSaver framework deprioritises timer accuracy for idle-state workloads.

### PreferencesViewController — CVDisplayLink (fast path)

`PreferencesViewController` creates a `CVDisplayLink` tied to the physical
display:

```swift
CVDisplayLinkCreateWithCGDisplay(displayID, &link)
CVDisplayLinkSetOutputCallback(displayLink, callback, context)
CVDisplayLinkStart(displayLink)
```

The callback fires once per vsync at the display's **native refresh rate**
(60 Hz on standard panels, 120 Hz on ProMotion). It reads the actual refresh
period from the display link timestamp and passes it straight to
`FruitView.animateOneFrame(framesPerSecond:)`.

### Observed ratio

| Display          | CVDisplayLink fps | ScreenSaverView timer fps | Ratio |
|------------------|-------------------|---------------------------|-------|
| ProMotion 120 Hz | ~120              | ~40                       | ~3×   |
| Standard 60 Hz   | ~60               | ~20–30                    | ~2–3× |

The `DebugStatsView` overlay confirms this: the FPS value reported by
`calculateFps()` inside `FruitScreensaver.animateOneFrame()` is consistently
2–3× lower than the FPS shown in the preferences preview.

## Proposed Fix

Replace the `ScreenSaverView` animation timer with a `CVDisplayLink` inside
`FruitScreensaver`, mirroring the approach already proven in
`PreferencesViewController`.

### Step 1 — Disable ScreenSaverView's built-in timer

Set `animationTimeInterval` to a very large value (or leave it at default) so
the framework's `NSTimer` effectively never fires. Override `animateOneFrame()`
to be a no-op (the CVDisplayLink callback will drive rendering instead).

```swift
animationTimeInterval = .infinity
```

### Step 2 — Add CVDisplayLink to FruitScreensaver

Port the display-link setup from `PreferencesViewController`:

1. Add `displayLink: CVDisplayLink?` and `DisplayLinkContext` (weak-ref
   wrapper) as private properties.
2. In `setupDisplayLink()`, create the link for the current screen's
   `CGDirectDisplayID`, set the output callback, and start it.
3. The callback computes `fps` from `inNow.pointee.videoTimeScale /
   videoRefreshPeriod` and dispatches to `DispatchQueue.main` to call
   `fruitView.animateOneFrame(framesPerSecond:)` and update the debug overlay.

### Step 3 — Handle display changes

When the screensaver window moves to a different screen (e.g. multi-monitor),
tear down and recreate the display link for the new display ID. The existing
`NSWindow.didChangeScreenNotification` observer can call `setupDisplayLink()`
(as PreferencesViewController already does via `screenDidChange()`).

### Step 4 — Handle pause / resume

- `viewDidMoveToWindow()` — stop the display link when `window == nil`, restart
  when re-attached.
- `willStop(_:)` — stop the display link to release resources before the
  screensaver engine terminates the process.

### Step 5 — Extract shared helper (optional refactor)

Both `FruitScreensaver` and `PreferencesViewController` will now contain
near-identical CVDisplayLink setup and teardown code. Extract a reusable
`DisplayLinkAnimator` helper (or protocol extension) to eliminate duplication:

```
DisplayLinkAnimator
  ├── start(on screen: NSScreen?)
  ├── stop()
  └── onFrame: ((_ fps: Int) -> Void)?
```

Both call sites would reduce to:

```swift
animator.onFrame = { [weak self] fps in
    self?.fruitView.animateOneFrame(framesPerSecond: fps)
    self?.updateDebugStatsIfNeeded(fps: fps)
}
animator.start(on: window?.screen)
```

### Step 6 — Validate

- Confirm via `DebugStatsView` that both paths now report matching FPS on the
  same display.
- Test on a ProMotion display (should reach ~120 fps).
- Test on a standard 60 Hz display (should reach ~60 fps).
- Test multi-monitor with mixed refresh rates (display link should rebind).
- Verify CPU/GPU usage does not regress — the extra frames are driven by
  hardware vsync so there should be no busy-wait overhead.

## Files Changed

| File | Change |
|------|--------|
| `FruitScreensaver/FruitScreensaver.swift` | Replace NSTimer loop with CVDisplayLink |
| `FruitScreensaver/Preferences/PreferencesViewController.swift` | Extract shared display-link code (Step 5) |
| New: `FruitFarm/DisplayLinkAnimator.swift` (optional) | Shared CVDisplayLink helper |

## Risks & Considerations

- **ScreenSaverView contract**: Apple's documentation does not explicitly
  guarantee that ignoring `animateOneFrame()` is safe. However, the timer is
  only a convenience; nothing in the framework enforces that rendering must
  happen inside that callback. Setting `animationTimeInterval = .infinity`
  effectively turns it off without fighting the framework.
- **Thread safety**: `CVDisplayLink` fires on a dedicated high-priority thread.
  All UI and layer mutations must be dispatched to the main thread, which the
  current `PreferencesViewController` implementation already does.
- **Legacy macOS**: `CVDisplayLink` is available since macOS 10.4 and is not
  deprecated. The newer `CADisplayLink` (macOS 14+) is an alternative but would
  raise the deployment target.
