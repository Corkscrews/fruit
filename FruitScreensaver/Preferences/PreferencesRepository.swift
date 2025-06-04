import Foundation
import FruitFarm

/// Protocol defining the interface for managing user preferences related to fruit 
/// background type.
protocol PreferencesRepository {
  /// Returns the user's default background fruit type.
  func defaultBackgroundType() -> FruitMode
  /// Updates the user's default background fruit type.
  func selectedFruitType(_ mode: FruitMode)
}

/// Concrete implementation of PreferencesRepository using UserDefaults for persistence.
class PreferencesRepositoryImpl: PreferencesRepository {
  
  /// The key used to store the default fruit type in UserDefaults.
  private let fruitTypeKey = "\(Bundle.main.bundleIdentifier!).defaultFruitType"
  private let randomFruitType = "random"

  /// Retrieves the default background fruit type from UserDefaults.
  /// - Returns: The stored FruitType if available, otherwise returns `.rainbow` as
  ///   the default.
  func defaultBackgroundType() -> FruitMode {
    // Attempt to fetch the raw value for the fruit type from UserDefaults.
    if let rawValue = UserDefaults.standard.string(forKey: fruitTypeKey) {
      if  rawValue == randomFruitType {
        return FruitMode.random
      }
      if let fruitType = FruitType(rawValue: rawValue) {
        return FruitMode.specific(fruitType)
      }
    }
    // Return the default type if not set or if set to "random".
    return FruitMode.specific(FruitType.rainbow)
  }

  /// Updates the default fruit type in UserDefaults.
  /// - Parameter type: The selectedFruitType to be set as default.
  func selectedFruitType(_ mode: FruitMode) {
    switch mode {
    case .random:
      UserDefaults.standard.set(randomFruitType, forKey: fruitTypeKey)
    case .specific(let fruitType):
      UserDefaults.standard.set(fruitType.rawValue, forKey: fruitTypeKey)
    }
    // Synchronize UserDefaults to ensure the value is saved immediately.
    UserDefaults.standard.synchronize()
    print("DDD \(defaultBackgroundType())")
  }
}
