#!/bin/zsh
# Give this job its own signing keychain, then use the same release path as a local upload.
set -euo pipefail
: "${RUNNER_TEMP:?Run this script on the CI runner}"
: "${APPLE_CERTIFICATE_BASE64:?Set the APPLE_CERTIFICATE_BASE64 repository secret}"
: "${APPLE_CERTIFICATE_PASSWORD:?Set the APPLE_CERTIFICATE_PASSWORD repository secret}"
: "${ASC_KEY_ID:?Set the ASC_KEY_ID repository secret}"
: "${ASC_ISSUER_ID:?Set the ASC_ISSUER_ID repository secret}"
: "${ASC_PRIVATE_KEY:?Set the ASC_PRIVATE_KEY repository secret}"

umask 077
signing_dir=$(mktemp -d "$RUNNER_TEMP/kosha-signing.XXXXXX")
keychain="$signing_dir/signing.keychain-db"
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$signing_dir"
}
trap cleanup EXIT

printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 --decode > "$signing_dir/certificate.p12"
export ASC_PRIVATE_KEY_PATH="$signing_dir/AuthKey_$ASC_KEY_ID.p8"
printf '%s' "$ASC_PRIVATE_KEY" > "$ASC_PRIVATE_KEY_PATH"
keychain_password=$(openssl rand -hex 32)
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$signing_dir/certificate.p12" -P "$APPLE_CERTIFICATE_PASSWORD" -t cert -f pkcs12 \
  -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain"
security list-keychains -d user -s "$keychain"

"${0:A:h}/release.sh"
