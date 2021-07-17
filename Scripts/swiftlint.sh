#!/bin/sh

# Courtesy of https://github.com/norio-nomura/action-swiftlint
# Execute SwiftLint, remove working directory from all paths and transform the log lines so they can be parsed by GitHub action as annotations.
set -o pipefail && swiftlint | sed -E "s/$(pwd|sed 's/\//\\\//g')\///" | sed -E 's/^(.*):([0-9]+):([0-9]+): (warning|error|[^:]+): (.*)/::\4 file=\1,line=\2,col=\3::\5/'
