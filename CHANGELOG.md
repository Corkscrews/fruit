# Changelog

## [1.3.4]

### Bug Fixes

 - Fixed 13 bugs found during code review:
   - Fixed layer leak in `FruitView.setupLayersOrUpdate()` where stale `BackgroundLayer`s accumulated on every mode change.
   - Fixed strong `self` capture in `randomlyChangeFruitType()` animation closure that kept torn-down views alive.
   - Fixed display link dangling pointer by introducing a `DisplayLinkContext` wrapper with a weak reference.
   - Restored Metal `init(layer:)` implementations so presentation layers render correctly.
   - Added missing `update(deltaTime:)` to `BackgroundLayer`.
   - Replaced double force-unwrap in `PreferencesRepositoryImpl` with `guard let` and a descriptive `fatalError`.
   - Made `preferencesRepository` non-optional in `PreferencesViewController`.
   - Fixed `MetalSolidLayer` discarding excess elapsed time on color transitions.
   - Recreate display link when window moves to a different screen.
   - Replaced force-unwraps in `setupLayersOrUpdate()` with `guard let`.
   - Replaced deprecated `lockFocus`/`unlockFocus` with `NSImage(size:flipped:drawingHandler:)`.
   - Removed `fatalError` default implementations from `Background` protocol extension in favor of compile-time enforcement.
   - Replaced `NSApplicationMain` with `app.run()` in `FruitShop/main.swift`.
 - Fixed all SwiftLint warnings.
 - Added Xcode build verification to CI workflow.

## [1.3.3]

### Bug Fixes

 - Fixed macOS Sonoma screensaver lifecycle bugs:
   - Detect real `isPreview` state from frame size (FB7486243).
   - Replace immediate `terminate` with delayed `exit(0)` to avoid black-screen race.
   - Add lame-duck pattern to handle zombie multi-instance stacking (FB19204084).
   - Refresh preferences on each `startAnimation` via `synchronize()`.
   - Override `startAnimation`/`stopAnimation` for proper lifecycle management.
   - Replace `fatalError` in Metal setup with graceful nil-guarded fallback.
 - Fixed mask and background layer `contentsScale` for external monitors. The fruit/leaf `CAShapeLayer` masks and `BackgroundLayer` defaulted to 1.0 regardless of display, causing jagged logo edges on HiDPI screens.
 - Fixed copyright notice to reflect MIT license.

## [1.3.2]

### Bug Fixes

 - Fixed critical issue where CPU usage would spike to 100% even when the screensaver was not in use. The `MetalView` was using `enableSetNeedsDisplay` instead of `isPaused` to control the render loop, which only prevented manual draw requests but did not stop the internal CVDisplayLink timer running at up to 120 FPS.

## [1.3.1]

### Features

 - Migrated `Solid`, `Linear Gradient` and `Circular Gradient` to MetalKit. Reduced CPU usage from around 60% to around 16%.


## [1.3.0]

### Features

 - Added more background modes. Now you can select between `Rainbow`, `Solid`, `Linear Gradient` and `Circular Gradient`.

## [1.3.0]

### Minor Changes

- Add thumbnail and correct the preview.
- Improve performance.
- Improved the GitHub Actions workflow for releases:
  - Added a step to extract the changelog for the current build number and use it as the release body.
  - Automated tagging and uploading of the `.saver` file to GitHub Releases.
- Added a shell script to extract the changelog for a specific version from `CHANGELOG.md`.

## [1.2]

### Major Changes

- Migrated all animation and drawing logic from Objective-C to Swift.
- Modularized code: separated view, helpers, and extensions for clarity.
- Split the view layer from the main logic for better separation of concerns.
- Introduced a new demo app, **FruitShop**, to showcase and test the view independently.
- Animation is now stable and time-based, independent of frame rate.
- Improved code documentation and readability throughout.
- Exposed a single public `animateOneFrame(framesPerSecond:)` API for external animation control.
- Add support to EDR.