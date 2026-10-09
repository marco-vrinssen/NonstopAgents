#!/bin/sh
# Builds Nonstop Agents with Xcode and runs the developer tools.
#   ./build.sh            build to build/Nonstop Agents.app, signed to run on this Mac
#   ./build.sh run        build and launch it
#   ./build.sh check      run the detection self-check (add --live to watch this Mac)
#   ./build.sh icon       render Design/Icon/AppIcon.svg into the app icon set
# App Store archives come from Xcode, or xcodebuild archive, with your team set.
set -eu
cd "$(dirname "$0")"

build() {
    # Signed ad hoc with the app's entitlements, so the sandbox applies as in the App Store build.
    xcodebuild -project NonstopAgents.xcodeproj -scheme "Nonstop Agents" -configuration Debug -destination "platform=macOS,arch=arm64" \
        -derivedDataPath build/xcode CONFIGURATION_BUILD_DIR="$PWD/build" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -quiet build
    echo "Built build/Nonstop Agents.app"
}

case "${1:-}" in
    check)
        mkdir -p build
        swiftc -swift-version 5 -Onone \
            NonstopAgents/Scanner.swift NonstopAgents/Agents.swift NonstopAgents/Power.swift Checks/main.swift -o build/checks
        shift
        build/checks "$@"
        ;;
    icon)
        mkdir -p build
        swiftc -O Design/Icon/render.swift -o build/render-icon
        build/render-icon Design/Icon/AppIcon.svg NonstopAgents/Assets.xcassets/AppIcon.appiconset
        ;;
    run)
        build
        pkill -x "Nonstop Agents" 2>/dev/null || true
        open "build/Nonstop Agents.app"
        ;;
    *) build ;;
esac
