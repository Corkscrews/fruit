# macOS Sonoma Screensaver Lifecycle Bug

## Why the issue happens

Starting with macOS Sonoma, Apple refactored screensavers to run inside a
separate `legacyScreenSaver.appex` host process, introduced alongside the new
`WallpaperAgent` that merges screensavers and wallpapers. This refactor broke
the `ScreenSaverView` lifecycle in several critical ways.

Apple's DTS Engineer acknowledged these bugs on the Developer Forums and
recommended filing enhancement requests for an appex-based screensaver API,
calling the legacy compatibility shim "a source of ongoing problems."

### 1. `stopAnimation` is never called

Apple's documentation says `stopAnimation` is called when the screensaver is
dismissed. In practice, **it is only called for the live preview thumbnail in
System Settings**. During normal screensaver operation (lock screen, hot corner,
idle timer) the method is never invoked. Your view keeps running silently in the
background with `animateOneFrame` still being called.

This was confirmed in Apple Developer Forums thread (FB13041503) where the
original reporter noted: "I do get the startAnimating calls, but never see any
stopAnimating calls."

### 2. Multiple instances stack up

Every time the screensaver activates, the framework creates a **new**
`ScreenSaverView` instance. The previous instance is never deallocated or
removed from the view hierarchy. Over several lock/unlock cycles this leads to
dozens of zombie views all animating simultaneously, consuming CPU, GPU, and
memory.

This was filed as FB19204084 with detailed reproduction steps. Users have
reported `legacyScreenSaver` consuming 1.3 GB and even up to 15 GB of RAM on
8 GB machines.

### 3. The host process never terminates

`legacyScreenSaver` stays alive indefinitely after the screensaver is
dismissed. Even with no visible output, Apple's internal framework code runs an
idle loop that wastes a small but measurable amount of CPU.

### 4. `isPreview` returns wrong values (FB7486243)

On Sonoma, `legacyScreenSaver.appex` always returns `true` for `isPreview` in
`init(frame:isPreview:)`, even when running as the actual full-screen
screensaver. The community-discovered workaround is to check the frame size:
if `frame.width > 400 && frame.height > 300`, it is the real screensaver, not
the preview thumbnail.

On macOS Tahoe, this bug changes behavior again -- `isPreview` returns `false`
even during preview mode. The ScreenSaverMinimal template now uses screen lock
detection (`CGSSessionScreenIsLocked`) as a workaround.

### 5. Preferences are cached and never refreshed

Because `legacyScreenSaver.appex` reuses old instances instead of creating new
ones, `ScreenSaverDefaults` values read during `init` are never updated. Users
who change preferences in System Settings won't see those changes take effect
until they reboot or log out.

### The net effect

Without any mitigation the screensaver silently spirals: each activation adds
another animating view, Metal render loops keep firing, CVDisplayLink timers
keep ticking, and the process never exits. Users see 100%+ CPU in Activity
Monitor from a screensaver they thought was off.

---

## macOS Tahoe (macOS 26) introduces new issues

These were reported in Apple Developer Forums thread by the Aerial screensaver
team:

| Bug | Feedback # | Description |
|-----|-----------|-------------|
| Duplicate instances | FB18697726 | When viewing the screensaver dialog in Wallpaper settings, the system launches **two** copies of `legacyScreenSaver` -- one fullscreen on the main screen, one in preview mode. |
| `isPreview` inverted | FB17895600 | `isPreview` is `false` when actually in preview mode. |
| Secondary monitor blank | FB19206021 | WKWebView-based screensavers don't display on secondary monitors. Also affects setups where at least one monitor uses a third-party screensaver. |
| Removed Settings pane | FB18698083 | The Screen Saver preference pane no longer exists as standalone. It is now a non-resizable modal inside Wallpaper settings. `open x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension` no longer works. |
| Xcode 26 SDK crash | FB19580645 | XIBs with `NSScrollView`/`NSOutlineView` crash on Sequoia and earlier due to a missing `BackdropView` class compiled into the Tahoe SDK. |

As of macOS 26 beta 7, none of these have been fixed.

---

## What Fruit currently implements

### `com.apple.screensaver.willstop` notification

The primary workaround. A `DistributedNotificationCenter` observer listens for
this undocumented notification that macOS posts just before hiding the
screensaver. On receipt, Fruit pauses all animations and calls
`NSApplication.shared.terminate(nil)` to kill the host process entirely.

```swift
// FruitScreensaver.swift
DistributedNotificationCenter.default.addObserver(
  self,
  selector: #selector(willStop(_:)),
  name: Notification.Name("com.apple.screensaver.willstop"),
  object: nil
)

@objc private func willStop(_ aNotification: Notification) {
  isPaused = true
  metalView?.isRenderingPaused = true
  if !isPreview {
    NSApplication.shared.terminate(nil)
  }
}
```

### `viewDidMoveToWindow` pausing

When the view is removed from its window hierarchy (`window == nil`), Fruit
pauses both the `animateOneFrame` loop and the MTKView render timer. This is a
defensive fallback that catches cases the `willstop` notification might miss.

### MTKView `isPaused` (v1.3.2 fix)

The previous implementation used `enableSetNeedsDisplay = true` to "stop"
rendering. This only prevents manual `setNeedsDisplay()` calls from triggering
draws -- the internal CVDisplayLink timer keeps firing `draw(in:)` at up to
120 FPS. The fix was to set `MTKView.isPaused = true`, which fully stops the
timer.

### Background layer throttling

All background layers (Solid, Linear Gradient, Circular Gradient, Rainbow) cap
their redraw rate to ~30 FPS using a `minUpdateInterval` check, regardless of
the display refresh rate.

---

## Is the implementation optimal?

The current implementation is **good** and solves the most critical problem
(runaway CPU), but there are several areas that could be improved based on the
latest research from the Aerial team and Wade Tregaskis.

### What works well

| Aspect | Why it's good |
|---|---|
| `willstop` + `terminate` | Kills the entire host process, preventing zombie views and idle CPU waste. |
| `viewDidMoveToWindow` guard | Defensive second layer in case `willstop` doesn't fire. |
| `MTKView.isPaused` | Correctly stops the CVDisplayLink timer, not just manual draws. |
| `deinit` cleanup | Observers, timers, and Metal resources are all explicitly released. |
| 30 FPS layer throttle | Prevents background layers from running at the display's native refresh rate. |

### What should be improved

#### 1. Immediate `terminate` causes a black-screen race condition

Calling `NSApplication.shared.terminate(nil)` synchronously inside the
`willstop` handler can race with the system trying to relaunch the screensaver.
If the user locks/unlocks quickly, the process may exit before macOS finishes
its cleanup, resulting in a black screen with no screensaver on the next
activation.

The Aerial ScreenSaverMinimal template uses a **2-second delay** with
`exit(0)` instead of `terminate`:

```swift
@objc private func willStop(_ aNotification: Notification) {
  isPaused = true
  metalView?.isRenderingPaused = true

  if !isPreview {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      exit(0)
    }
  }
}
```

`exit(0)` is preferred over `NSApplication.shared.terminate(nil)` because
`terminate` triggers `applicationShouldTerminate` and other AppKit delegate
callbacks that may not be appropriate inside `legacyScreenSaver.appex`. The
2-second delay avoids the race condition with rapid lock/unlock cycles.

Alternatively, Wade Tregaskis recommends an idle timeout of ~65 seconds to
allow rapid re-engagement without a full process restart.

#### 2. No lame-duck / multi-instance handling

Because `terminate` kills the process, the multi-instance problem is largely
side-stepped. But if `terminate` fails or is delayed (see point 1), a second
activation will create a new `ScreenSaverView` while the old one is still
animating. This is confirmed as a major ongoing bug (FB19204084).

A more robust approach is to broadcast a local notification from each new
instance and have older instances mark themselves as lame-duck:

```swift
static let newInstanceNotification = Notification.Name("com.fruit.NewInstance")
var lameDuck = false

private func setup() {
  NotificationCenter.default.post(
    name: Self.newInstanceNotification, object: self
  )
  NotificationCenter.default.addObserver(
    self,
    selector: #selector(neuter(_:)),
    name: Self.newInstanceNotification,
    object: nil
  )
}

@objc func neuter(_ notification: Notification) {
  guard notification.object as? FruitScreensaver !== self else { return }
  lameDuck = true
  isPaused = true
  metalView?.isRenderingPaused = true
  removeFromSuperview()
  NotificationCenter.default.removeObserver(self)
  DistributedNotificationCenter.default.removeObserver(self)
}
```

Then guard in `animateOneFrame`:

```swift
override func animateOneFrame() {
  super.animateOneFrame()
  guard !isPaused, !lameDuck else { return }
  fruitView.animateOneFrame(framesPerSecond: calculateFps())
}
```

#### 3. `isPreview` bug is not handled (FB7486243)

On Sonoma, `isPreview` is always `true` even during full-screen screensaver
operation. Fruit relies on `isPreview` to decide whether to create the
`MetalView` and whether to `terminate` on `willstop`:

```swift
if !isPreview {
  setupMetalView()
  addScreenDidChangeNotification()
}
// ...
if !isPreview {
  NSApplication.shared.terminate(nil)
}
```

If `isPreview` is incorrectly `true`, the EDR MetalView is never created and
the process is never terminated on dismissal -- defeating the primary
workaround.

The community-standard fix is to detect the real preview state from the frame
size:

```swift
var actualIsPreview: Bool

// In init(frame:isPreview:)
if frame.width > 400 && frame.height > 300 {
  actualIsPreview = false  // Real screensaver, not preview
} else {
  actualIsPreview = true   // System Settings thumbnail
}
```

On Tahoe, the bug inverts (isPreview is `false` in preview mode), so the
ScreenSaverMinimal template uses `CGSSessionScreenIsLocked()` instead.

#### 4. Preferences are never refreshed

`PreferencesRepository` is created once during `init` and
`defaultFruitMode()` is read once. Because `legacyScreenSaver.appex` reuses
old instances, any preference changes made in System Settings are ignored until
reboot.

Fix: call `screensaverDefaults.synchronize()` (to flush the cache) and re-read
preferences at the start of each screensaver activation:

```swift
override func startAnimation() {
  super.startAnimation()
  isPaused = false
  metalView?.isRenderingPaused = false
  let mode = preferencesRepository.defaultFruitMode()
  fruitView.update(mode: mode)
}
```

This also requires `ScreenSaverDefaults.synchronize()` to be called before
reading to ensure the in-memory cache is refreshed from disk.

#### 5. `startAnimation` / `stopAnimation` are not overridden

While `stopAnimation` is broken in Sonoma for normal usage, it **is** still
called for the System Settings live preview. Overriding both methods would let
you cleanly manage the animation lifecycle:

```swift
override func startAnimation() {
  super.startAnimation()
  guard !lameDuck else { return }
  isPaused = false
  metalView?.isRenderingPaused = false
}

override func stopAnimation() {
  isPaused = true
  metalView?.isRenderingPaused = true
  super.stopAnimation()
}
```

This also provides a natural hook for refreshing preferences (see point 4).

#### 6. `fatalError` in Metal layer setup

All Metal layer initializers use `fatalError()` if Metal device creation or
pipeline compilation fails:

```swift
guard let device = MTLCreateSystemDefaultDevice() else {
  fatalError("Metal is not supported on this device for MetalSolidLayer")
}
```

In the screensaver context, a `fatalError` crashes the entire
`legacyScreenSaver.appex` process, potentially leaving the user with a black
screen and no way to dismiss it except force-quit. These should be converted to
graceful failures that fall back to the non-Metal `RainbowsLayer`.

#### 7. `init(layer:)` in Metal layers does not copy Metal resources

Core Animation may call `init(layer:)` to create a "presentation" copy of a
layer during implicit animations. The current Metal layer implementations
(`MetalSolidLayer`, `MetalLinearGradientLayer`, `MetalCircularGradientLayer`)
all override `init(layer:)` but only call `super.init(layer:)`, leaving the
copy without a Metal device, pipeline state, or buffers. If Core Animation
triggers a copy, the layer will silently fail to render.

There is a commented-out implementation in `SolidLayer.swift` with the note:

> TODO: Can't fix this, something is wrong with the invalidation of strong
> references.

The pragmatic fix is to guard `display()` against nil Metal state:

```swift
override func display() {
  guard let device = self.device,
        let pipelineState = self.pipelineState,
        let commandQueue = self.commandQueue,
        let vertexBuffer = self.vertexBuffer,
        let drawable = nextDrawable() else { return }
  // ... render ...
}
```

---

## Summary of recommended changes

| Priority | Issue | Fix |
|----------|-------|-----|
| **Critical** | `isPreview` always `true` on Sonoma | Detect real state from frame size |
| **Critical** | Immediate `terminate` race condition | Use `exit(0)` with 2s delay |
| **High** | No multi-instance handling | Lame-duck pattern via local notification |
| **High** | Preferences never refreshed | Re-read in `startAnimation`, call `synchronize()` |
| **Medium** | Missing `startAnimation`/`stopAnimation` | Override both for lifecycle management |
| **Medium** | `fatalError` in Metal setup | Graceful fallback to `RainbowsLayer` |
| **Low** | `init(layer:)` leaves invalid Metal state | Guard `display()` against nil state |

---

## References

- [Apple Developer Forums -- Third-party screensavers not quitting on Sonoma (FB13041503)](https://developer.apple.com/forums/thread/738547)
- [Apple Developer Forums -- macOS 26 Tahoe Screen Saver issues (FB17895600, FB18697726, FB19204084)](https://developer.apple.com/forums/thread/787444)
- [Wade Tregaskis -- How to make a macOS screen saver](https://wadetregaskis.com/how-to-make-a-macos-screen-saver/)
- [Marton Braun -- Building a macOS screen saver in Kotlin](https://zsmb.co/building-a-macos-screen-saver-in-kotlin/)
- [Aerial ScreenSaverMinimal template](https://github.com/AerialScreensaver/ScreenSaverMinimal)
- [StackOverflow -- Audio keeps playing after screensaver ends](https://stackoverflow.com/questions/66861833/audio-keeps-playing-after-screensaver-ends)
- [Apple Discussions -- legacyScreenSaver using 1.3 GB RAM](https://discussions.apple.com/thread/255256761)
