#!/bin/sh
# ci_post_xcodebuild.sh — Xcode Cloud hook: runs after xcodebuild.
#
# Use this for post-build tasks like uploading dSYMs, notifying Slack,
# or running custom test reports.

set -e

echo "▸ [Xcode Cloud] Post-xcodebuild hook running…"
echo "▸ CI_RESULT:       ${CI_RESULT}"          # succeeded | failed
echo "▸ CI_ARCHIVE_PATH: ${CI_ARCHIVE_PATH}"

if [ "${CI_RESULT}" = "succeeded" ]; then
    echo "✓ Build succeeded — archive ready for TestFlight distribution."
else
    echo "✗ Build failed."
fi

echo "✓ Post-xcodebuild complete."
