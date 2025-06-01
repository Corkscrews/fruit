#!/bin/bash

set -e

xcodebuild -showBuildSettings -scheme FruitScreensaver | grep MARKETING_VERSION | awk -F= '{gsub(/^[ \t]+/, "", $2); print $2; exit}'