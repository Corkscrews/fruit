#!/bin/bash

set -e

xcodebuild -scheme FruitScreensaver -configuration Release -archivePath build/FruitScreensaver.xcarchive archive

SAVER_SRC=$(find build/FruitScreensaver.xcarchive/Products -type d -name "FruitScreensaver.saver" | head -n 1)
if [ -z "$SAVER_SRC" ]; then
  echo "Error: .saver bundle not found in archive." >&2
  exit 1
fi

cp -R "$SAVER_SRC" build/FruitScreensaver.saver
rm -rf build/FruitScreensaver.xcarchive
