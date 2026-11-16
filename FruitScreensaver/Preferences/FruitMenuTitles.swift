import FruitFarm

/// Combo box titles for the background types.
enum FruitMenuTitles {
  private static let titles: [FruitType: String] = [
    .rainbow: "Rainbow Bars",
    .solid: "Solid",
    .linearGradient: "Linear Gradient",
    .circularGradient: "Circular Gradient",
    .psychedelic: "Psychedelic",
    .california: "California",
    .liquid: "Liquid",
    .puppy: "Puppy",
    .warp: "Warp Speed",
    .ocean: "Irish Ocean",
    .glass: "Glass",
    .metallic: "Metallic",
    .pogo: "POGO",
    .glue: "Glue",
    .bands: "Bands",
    .candy: "Candy"
  ]

  /// A "Random" option followed by every background type, in `FruitType` order.
  static func menuItems() -> [String] {
    var items: [String] = ["Random"]
    items.append(contentsOf: FruitType.allCases.map { titles[$0] ?? $0.rawValue })
    return items
  }
}
