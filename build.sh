#!/bin/sh
# Builds Nonstop Agents with Xcode and runs the developer tools.
#   ./build.sh            build to build/Nonstop Agents.app, signed to run on this Mac
#   ./build.sh run        build and launch it
#   ./build.sh release    universal Release build, zipped for a GitHub release, with Sparkle's signed appcast.xml
#   ./build.sh check      run the detection self-check (add --live to watch this Mac)
#   ./build.sh icon       render Design/Icon/AppIcon.svg into the app icon set
# App Store archives come from Xcode, or xcodebuild archive, with your team set.
set -eu
cd "$(dirname "$0")"

# Builds the app into a folder, signed ad hoc with its entitlements, so the sandbox applies as in the App Store build.
# The hardened runtime stays off: it serves notarization, which needs a paid account, and it refuses to load
# Sparkle.framework, signed by Sparkle's team, into an ad hoc app. Xcode archives keep it on.
build() {
    configuration=$1 destination=$2 out=$3
    xcodebuild -project NonstopAgents.xcodeproj -scheme "Nonstop Agents" -configuration "$configuration" -destination "$destination" \
        -derivedDataPath build/xcode CONFIGURATION_BUILD_DIR="$PWD/$out" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO -quiet build
    echo "Built $out/Nonstop Agents.app"
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
        build Debug "platform=macOS,arch=arm64" build
        pkill -x "Nonstop Agents" 2>/dev/null || true
        open "build/Nonstop Agents.app"
        ;;
    release)
        version=$(plutil -extract CFBundleShortVersionString raw Config/Info.plist)
        rm -rf build/release
        build Release "generic/platform=macOS" build/release
        ditto -c -k --keepParent "build/release/Nonstop Agents.app" "build/NonstopAgents-$version.zip"

        # The unversioned copy keeps the README's install command working for every release.
        cp "build/NonstopAgents-$version.zip" build/NonstopAgents.zip

        # Sparkle's update feed, pointing at this release's zip and signed with the key in the login keychain.
        rm -rf build/appcast && mkdir -p build/appcast && cp "build/NonstopAgents-$version.zip" build/appcast/
        if [ -f "Releases/$version.html" ]; then cp "Releases/$version.html" "build/appcast/NonstopAgents-$version.html"; fi
        build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast \
            --download-url-prefix "https://github.com/marco-vrinssen/NonstopAgents/releases/download/v$version/" build/appcast
        cp build/appcast/appcast.xml build/appcast.xml
        echo "Zipped build/NonstopAgents-$version.zip and build/NonstopAgents.zip, wrote build/appcast.xml"
        ;;
    *) build Debug "platform=macOS,arch=arm64" build ;;
esac
