#!/bin/sh
# ci_pre_xcodebuild.sh — Xcode Cloud hook: runs before xcodebuild.
#
# Use this to inject build-time config, bump version numbers, or generate
# source files that depend on CI environment variables.

set -e

echo "▸ [Xcode Cloud] Pre-xcodebuild hook running…"

# Auto-increment build number from Xcode Cloud's counter.
if [ -n "${CI_BUILD_NUMBER}" ]; then
    echo "▸ Setting CURRENT_PROJECT_VERSION to ${CI_BUILD_NUMBER}"
    cd "${CI_WORKSPACE}/ios-spark-ai"

    # Update build number for all targets via agvtool.
    agvtool new-version -all "${CI_BUILD_NUMBER}" 2>/dev/null || true
fi

echo "✓ Pre-xcodebuild complete."
