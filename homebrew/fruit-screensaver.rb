cask "fruit-screensaver" do
  version "1.3.0"
  sha256 "942f8d4d2524d5b1764bbf4a03687b50237a9781bed9218f3f9c32550a426647"

  url "https://github.com/Corkscrews/fruit/releases/download/#{version}/Fruit.saver.tar.gz"
  name "Fruit Screensaver"
  desc "Screensaver of the vintage Apple logo made purely with NSBezierPath and masks in Swift"
  homepage "https://github.com/Corkscrews/fruit"
  license "MIT"

  screen_saver "Fruit.saver"

  zap trash: "~/Library/Screen Savers/Fruit.saver"
end
