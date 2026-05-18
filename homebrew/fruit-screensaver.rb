# This cask below is just a template of what you can find in the official Homebrew cask repository.
cask "fruit-screensaver" do
  version "1.3.4"
  # Generate a new sha256 with `shasum -a 256 Fruit.saver.tar.gz` when deploying a new version.
  # sha256 "871a2973ba6230dc5142a5e56e4465e72ee1ae8e9ea4bcb13255c21124651efe"

  url "https://github.com/Corkscrews/fruit/releases/download/#{version}/Fruit.saver.tar.gz"
  name "Fruit Screensaver"
  desc "Screensaver of the vintage Apple logo"
  homepage "https://github.com/Corkscrews/fruit"

  screen_saver "Fruit.saver"

  zap trash: "~/Library/Screen Savers/Fruit.saver"
end
