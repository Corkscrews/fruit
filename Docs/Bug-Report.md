# Bug Report

Code review of the Fruit screensaver codebase. Findings are grouped by severity.

---

## Critical

### 1. Layer leak in `FruitView.setupLayersOrUpdate()` -- FIXED

**File:** `FruitFarm/FruitView.swift`

When the fruit mode changes via `update(mode:)`, `fruitBackground` is removed from
its superlayer and set to `nil`, which triggers a redraw. Inside `setupLayersOrUpdate()`,
`self.backgroundLayer` was set to `nil` (releasing the strong reference) but the old
`BackgroundLayer` was **never removed from the layer tree**. A new `BackgroundLayer` was
then added as a sublayer alongside the orphaned one.

Every mode change (or every ~60 s in random mode) added another stale layer. Over a
long screensaver session this leaked memory and accumulated unnecessary sublayers.

**Fix:** Added `backgroundLayer?.removeFromSuperlayer()` before setting it to `nil`,
both in `setupLayersOrUpdate()` and `recreateLayersForNewScale()`.

---

### 2. Strong `self` capture in animation closure -- FIXED

**File:** `FruitFarm/FruitView.swift`

The outer `NSAnimationContext.runAnimationGroup` closure in `randomlyChangeFruitType()`
captured `self` strongly. If the view was removed during the fade-out animation, the
strong reference kept it alive and the completion handler ran on a partially-torn-down
view.

**Fix:** Added `[weak self]` to the outer closure.

---

### 3. Display link race condition (`Unmanaged.passUnretained`) -- FIXED

**File:** `FruitScreensaver/Preferences/PreferencesViewController.swift`

The CVDisplayLink callback received an `Unmanaged.passUnretained(self)` pointer. The
display link runs on a Core Video background thread and did not retain the view
controller. If the view controller was deallocated, the callback would dereference a
dangling pointer.

**Fix:** Introduced a `DisplayLinkContext` wrapper class with a `weak` reference to
the controller. The display link callback now checks the weak reference before
dispatching work, and the main-queue closure also uses `[weak controller]`.

---

### 4. Metal `init(layer:)` overrides are empty -- FIXED

**Files:**
- `FruitFarm/Backgrounds/Types/SolidLayer.swift`
- `FruitFarm/Backgrounds/Types/LinearGradientLayer.swift`
- `FruitFarm/Backgrounds/Types/CircularGradientLayer.swift`

Core Animation calls `init(layer:)` to create **presentation layers** during implicit
animations and layer-tree snapshots. All three Metal layer subclasses had this
initializer's body commented out. The resulting presentation layers had `nil` Metal
resources and would fail to render.

**Fix:** Uncommented and cleaned up all three `init(layer:)` implementations. Each now
copies the source layer's device, animation state, and recreates Metal resources
(pipeline, buffers).

---

## Medium

### 5. `BackgroundLayer` missing `update(deltaTime:)` implementation -- FIXED

**File:** `FruitFarm/Backgrounds/BackgroundLayer.swift`

`BackgroundLayer` conformed to `Background` but did not implement
`update(deltaTime:)`. The protocol extension's default fell through to
`fatalError("Must override update(deltaTime:)")`.

**Fix:** Added a no-op implementation: `func update(deltaTime: CGFloat) { }`.

---

### 6. Double force-unwrap in `PreferencesRepositoryImpl` -- FIXED

**File:** `FruitScreensaver/Preferences/PreferencesRepository.swift`

Both `bundleIdentifier` and the `ScreenSaverDefaults` initializer were force-unwrapped.
A misconfigured bundle would crash at property access time with no diagnostic.

**Fix:** Replaced with `guard let` and a descriptive `fatalError` message that
identifies the root cause.

---

### 7. Force-unwrap of `preferencesRepository` in closures -- FIXED

**File:** `FruitScreensaver/Preferences/PreferencesViewController.swift`

`preferencesRepository` was declared as `PreferencesRepository?` but force-unwrapped
in lazy initializers and a callback closure.

**Fix:** Changed `preferencesRepository` from `var ... : PreferencesRepository?` to
`let preferencesRepository: PreferencesRepository` since it is always provided at init.
Removed all force-unwraps.

---

### 8. `MetalSolidLayer` loses excess time on color transition -- FIXED

**File:** `FruitFarm/Backgrounds/Types/SolidLayer.swift`

When `elapsedTime` exceeded `secondsPerColor`, the excess was discarded (`= 0`)
instead of carried over. The other two gradient layers correctly used
`while elapsedTime >= secondsPerColor { elapsedTime -= secondsPerColor }`.

**Fix:** Replaced `if ... = 0` with the same `while ... -=` pattern as the gradient
layers.

---

### 9. Display link not recreated on screen change -- FIXED

**File:** `FruitScreensaver/Preferences/PreferencesViewController.swift`

`addScreenDidChangeNotification()` observed `NSWindow.didChangeScreenNotification`
but only called `checkEDR()`. If the window moved to a display with a different
refresh rate, the CVDisplayLink remained bound to the original display.

**Fix:** Added a `screenDidChange()` handler that calls both `checkEDR()` and
`setupDisplayLink()`, which now stops the old link and creates a new one for the
current display.

---

## Low / Code Quality

### 10. Multiple force-unwraps in `setupLayersOrUpdate()` -- FIXED

**File:** `FruitFarm/FruitView.swift`

Force-unwraps of `fruitBackground!` and `backgroundLayer!` provided no safety net if
the control flow was refactored.

**Fix:** Replaced with `guard let` / safe unwrapping via local variables.

---

### 11. Deprecated `lockFocus`/`unlockFocus` API -- FIXED

**File:** `FruitFarm/MetalView.swift`

`NSImage.lockFocus()` and `unlockFocus()` have been deprecated since macOS 10.14.

**Fix:** Replaced with `NSImage(size:flipped:drawingHandler:)`.

---

### 12. `Background` protocol uses `fatalError` defaults instead of compile-time enforcement -- FIXED

**File:** `FruitFarm/Backgrounds/Background.swift`

The protocol declared methods and then provided default implementations in an
extension that called `fatalError()`. Conforming types were not required by the
compiler to implement these methods.

**Fix:** Removed the default `fatalError` extension. The compiler now enforces
conformance at build time. All existing conforming types already implement the
required methods.

---

### 13. `main.swift` mixes manual delegate assignment with `NSApplicationMain` -- FIXED

**File:** `FruitShop/main.swift`

`NSApplicationMain` creates its own `NSApplication` instance and enters the run loop.
Manually setting a delegate beforehand and then calling `NSApplicationMain` was
unconventional and fragile.

**Fix:** Replaced `NSApplicationMain(...)` with `app.run()` to keep the manual
delegate setup consistent.
