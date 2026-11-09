#!/bin/bash
# Type-checks the app sources against the simulator SDK without Xcode's build system.
# Quicker than a full build when only compiler errors matter.
set -euo pipefail
cd "$(dirname "$0")/.."
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
find Suite -name '*.swift' -print0 |
    xargs -0 xcrun swiftc -typecheck -swift-version 6 -sdk "$sdk" -target arm64-apple-ios18.0-simulator
