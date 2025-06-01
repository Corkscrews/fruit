class Fruit < Formula
  desc "Fruit: Screensaver of the vintage Apple logo made purely with NSBezierPath and masks in Swift."
  homepage "https://github.com/Corkscrews/fruit"
  url "https://github.com/Corkscrews/fruit/archive/refs/tags/1.3.0"
  license "MIT"

  depends_on xcode: ["14.0", :build]
  depends_on macos: :big_sur

  def install
    bin_url = "https://github.com/Corkscrews/fruit/releases/download/1.3.0/Fruit.saver.tar.gz"
    bin_sha256 = "77d3a728ff1383b1b79ce516c30b938488e8bb673404901016b9b77f0d6c38da"

    require "open-uri"

    resource("Fruit.saver") do
      url bin_url
      sha256 bin_sha256
    end

    resource("Fruit.saver").stage do
      prefix.install "Fruit.saver"
    end
  end

  test do
    # Test that the app bundle exists after install
    assert_predicate prefix/"Fruit.saver", :exist?
  end
end 