import Foundation
import ScreenSaver
import FruitFarm

/// Protocol defining the interface for managing user preferences related to fruit 
/// background type.
protocol PreferencesRepository {
  /// Returns the user's default background fruit type.
  func defaultFruitMode() -> FruitMode
  /// Updates the user's default background fruit type.
  func updateDefaultFruitMode(_ mode: FruitMode)
  /// Flushes the in-memory defaults cache so the next read picks up
  /// changes written by another process (e.g. System Settings).
  func reload()
}

/// Concrete implementation of PreferencesRepository using ScreenSaverDefaults 
/// for persistence.
class PreferencesRepositoryImpl: PreferencesRepository {

  private lazy var screensaverDefaults: ScreenSaverDefaults = {
    guard let bundleId = Bundle(for: type(of: self)).bundleIdentifier,
          let defaults = ScreenSaverDefaults(forModuleWithName: bundleId) else {
      fatalError("Failed to create ScreenSaverDefaults — missing CFBundleIdentifier in Info.plist")
    }
    return defaults
  }()

  /// The key used to store the default fruit type in ScreenSaverDefaults.
  enum Keys: String {
    case fruitTypeKey = "defaultFruitType"
    case randomFruitType = "random"
  }

  /// Retrieves the default background fruit type from ScreenSaverDefaults.
  /// - Returns: The stored FruitType if available, otherwise returns `.rainbow` as
  ///   the default.
  func defaultFruitMode() -> FruitMode {
    // Attempt to fetch the raw value for the fruit type
    // from ScreenSaverDefaults.
    if let rawValue = screensaverDefaults.string(
      forKey: Keys.fruitTypeKey.rawValue
    ) {
      if rawValue == Keys.randomFruitType.rawValue {
        return FruitMode.random
      }
      if let fruitType = FruitType(rawValue: rawValue) {
        return FruitMode.specific(fruitType)
      }
    }
    // Return the FruitType.rainbow type if not set.
    return FruitMode.specific(FruitType.rainbow)
  }

  /// Updates the default fruit type in ScreenSaverDefaults.
  /// - Parameter type: The updateDefaultFruitMode to be set as default.
  func updateDefaultFruitMode(_ mode: FruitMode) {
    switch mode {
    case .random:
      screensaverDefaults.set(
        Keys.randomFruitType.rawValue,
        forKey: Keys.fruitTypeKey.rawValue
      )
    case .specific(let fruitType):
      screensaverDefaults.set(
        fruitType.rawValue,
        forKey: Keys.fruitTypeKey.rawValue
      )
    }
    screensaverDefaults.synchronize()
  }

  func reload() {
    screensaverDefaults.synchronize()
  }
}
