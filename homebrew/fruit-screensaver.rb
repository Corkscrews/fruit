# Copy of the cask published in https://github.com/Corkscrews/homebrew-tap (Casks/fruit-screensaver.rb).
cask "fruit-screensaver" do
  version "1.3.5"
  sha256 "683567e3dfe3adb8f18535b28a64df8cc6d75e575866262e5e84fa39f2f6d4b6"

  url "https://github.com/Corkscrews/fruit/releases/download/#{version}/Fruit.saver.tar.gz"
  name "Fruit Screensaver"
  desc "Screensaver of the vintage Apple logo"
  homepage "https://github.com/Corkscrews/fruit"

  depends_on :macos

  screen_saver "Fruit.saver"

  zap :not_required
end
