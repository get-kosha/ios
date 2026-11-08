#!/bin/zsh
# Xcode Cloud runs this right after cloning. The Xcode project is generated from project.yml and isn't in the repo, so
# install XcodeGen and generate it before Xcode Cloud resolves packages and builds the Kosha scheme.
set -euo pipefail
brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate
