@frozen
public enum FruitMode: Equatable {
  case random
  case specific(FruitType)
}

@frozen
public enum FruitType: String, CaseIterable {
  case rainbow
  case solid
  case linearGradient
  case circularGradient
}
