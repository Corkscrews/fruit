# Changelog

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