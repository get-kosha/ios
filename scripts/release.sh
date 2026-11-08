#!/bin/zsh
# Archives Kosha for the App Store and uploads it to App Store Connect (TestFlight), signed automatically with the
# Xcode account for team 654ASRW868. The build number is the commit count, so every upload has a new one; the version
# is MARKETING_VERSION in project.yml.
#
#   scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
build=$(git rev-list --count HEAD)
xcodegen generate
rm -rf build/release
xcodebuild -project Kosha.xcodeproj -scheme Kosha -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/release/Kosha.xcarchive -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build" archive
xcodebuild -exportArchive -archivePath build/release/Kosha.xcarchive -exportOptionsPlist ExportOptions.plist \
  -exportPath build/release -allowProvisioningUpdates
echo "Uploaded build $build"
