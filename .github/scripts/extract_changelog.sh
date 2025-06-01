#!/bin/bash

set -e

awk "/## \\[${1}\\]/ {flag=1; next} /^## \\[/ {flag=0} flag" CHANGELOG.md