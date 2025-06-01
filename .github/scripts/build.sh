#!/bin/bash

set -e

xcodebuild -scheme Fruit -configuration Release -archivePath build/Fruit.xcarchive archive

SAVER_SRC=$(find build/Fruit.xcarchive/Products -type d -name "Fruit.saver" | head -n 1)
if [ -z "$SAVER_SRC" ]; then
  echo "Error: .saver bundle not found in archive." >&2
  exit 1
fi

cp -R "$SAVER_SRC" build/Fruit.saver
rm -rf build/Fruit.xcarchive
