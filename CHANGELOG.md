# Changelog

## [1.3]

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