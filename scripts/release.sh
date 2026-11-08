#!/bin/zsh
# Archives Kosha for the App Store and uploads it to App Store Connect (TestFlight), signed automatically with the
# Xcode account for team 654ASRW868, or the App Store Connect API key in CI. The build number is the commit count;
# a new commit is needed for a new upload. The version is MARKETING_VERSION in project.yml.
#
#   scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
auth=()
if [[ -n "${ASC_PRIVATE_KEY_PATH:-}${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]]; then
  : "${ASC_PRIVATE_KEY_PATH:?Set the path to the App Store Connect private key}"
  : "${ASC_KEY_ID:?Set the App Store Connect key ID}"
  : "${ASC_ISSUER_ID:?Set the App Store Connect issuer ID}"
  [[ -s "$ASC_PRIVATE_KEY_PATH" ]] || { echo "App Store Connect private key file is missing or empty" >&2; exit 1; }
  auth=(-authenticationKeyPath "$ASC_PRIVATE_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
build=$(git rev-list --count HEAD)
xcodegen generate
rm -rf build/release
xcodebuild -project Kosha.xcodeproj -scheme Kosha -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/release/Kosha.xcarchive -allowProvisioningUpdates "${auth[@]}" CURRENT_PROJECT_VERSION="$build" archive
xcodebuild -exportArchive -archivePath build/release/Kosha.xcarchive -exportOptionsPlist ExportOptions.plist \
  -exportPath build/release -allowProvisioningUpdates "${auth[@]}"
echo "Uploaded build $build"
