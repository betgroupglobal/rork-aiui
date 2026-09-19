#!/bin/sh
# ci_post_clone.sh — Xcode Cloud hook: runs after the repo is cloned.
#
# Use this to install dependencies, set up environment, or generate files
# that aren't checked into source control.

set -e

echo "▸ [Xcode Cloud] Post-clone hook running…"
echo "▸ CI_WORKSPACE:   ${CI_WORKSPACE}"
echo "▸ CI_BRANCH:      ${CI_BRANCH}"
echo "▸ CI_COMMIT:      ${CI_COMMIT}"
echo "▸ CI_BUILD_NUMBER: ${CI_BUILD_NUMBER}"

# If you use CocoaPods, SPM resolved packages, or other dependency managers,
# install them here. Example:
# cd "${CI_WORKSPACE}/ios-spark-ai"
# pod install

echo "✓ Post-clone complete."
