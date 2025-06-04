import FruitFarm

protocol PreferencesRepository {
  func defaultBackgroundType() -> FruitType
}

class PreferencesRepositoryImpl: PreferencesRepository {

  func defaultBackgroundType() -> FruitType {
    return FruitType.rainbow
  }

}

