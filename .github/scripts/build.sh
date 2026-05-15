#!/bin/bash

set -e

INSTALL_DIR="$HOME/Library/Screen Savers"
SAVER_NAME="Fruit.saver"

rm -rf build/Fruit.xcarchive build/"$SAVER_NAME"

xcodebuild -scheme Fruit -configuration Release -archivePath build/Fruit.xcarchive archive

SAVER_SRC=$(find build/Fruit.xcarchive/Products -type d -name "$SAVER_NAME" | head -n 1)
if [ -z "$SAVER_SRC" ]; then
  echo "Error: .saver bundle not found in archive." >&2
  exit 1
fi

cp -R "$SAVER_SRC" build/"$SAVER_NAME"
rm -rf build/Fruit.xcarchive

echo "Build: build/$SAVER_NAME"

if [ "$1" = "--install" ]; then
  killall legacyScreenSaver 2>/dev/null || true
  rm -rf "$INSTALL_DIR/$SAVER_NAME"
  cp -R build/"$SAVER_NAME" "$INSTALL_DIR/$SAVER_NAME"
  xattr -dr com.apple.quarantine "$INSTALL_DIR/$SAVER_NAME" 2>/dev/null || true
  echo "Installed to: $INSTALL_DIR/$SAVER_NAME"
fi
