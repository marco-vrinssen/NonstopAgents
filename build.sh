#!/bin/sh
# Builds Until without Xcode, using the Swift toolchain from the Command Line Tools.
#   ./build.sh            direct edition (Developer ID style) -> build/Until.app
#   ./build.sh appstore   sandboxed App Store edition         -> build/AppStore/Until.app
#   ./build.sh run        build the direct edition and launch it
#   ./build.sh check      run the detection self-check (add --live to watch this Mac)
#   ./build.sh icon       render Design/Icon/AppIcon.svg into the app icon set
set -eu
cd "$(dirname "$0")"

SOURCES=$(find Until -name '*.swift' | sort)
TARGET=15.0
FLAGS="-swift-version 5 -O -whole-module-optimization"

checks() {
    mkdir -p build
    swiftc -swift-version 5 -Onone -target "arm64-apple-macos$TARGET" \
        Until/Scanner.swift Until/Agents.swift Until/Power.swift Checks/main.swift -o build/checks
    shift
    build/checks "$@"
}

bundle() {
    edition=$1 out=$2 entitlements=$3 defines=$4 identifier=$5
    app="$out/Until.app"
    rm -rf "$app" "$out/obj"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$out/obj"

    for arch in arm64 x86_64; do
        # shellcheck disable=SC2086
        swiftc $FLAGS $defines -target "$arch-apple-macos$TARGET" -module-name Until \
            $SOURCES -o "$out/obj/Until-$arch"
    done
    lipo -create "$out"/obj/Until-* -output "$app/Contents/MacOS/Until"

    sed "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$identifier/" Config/Info.plist > "$app/Contents/Info.plist"
    printf 'APPL????' > "$app/Contents/PkgInfo"
    cp Until/PrivacyInfo.xcprivacy "$app/Contents/Resources/"
    iconset="$out/obj/AppIcon.iconset"
    mkdir -p "$iconset"
    cp Until/Assets.xcassets/AppIcon.appiconset/icon_*.png "$iconset/"
    iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
    rm -rf "$out/obj"

    # Ad-hoc signature with the edition's entitlements. Distribution signing happens in Xcode.
    codesign --force --sign - --options runtime --entitlements "$entitlements" "$app"
    echo "Built $edition edition: $app"
}

case "${1:-}" in
    check) checks "$@" ;;
    icon)
        mkdir -p build
        swiftc -O Design/Icon/render.swift -o build/render-icon
        build/render-icon Design/Icon/AppIcon.svg Until/Assets.xcassets/AppIcon.appiconset
        ;;
    appstore) bundle "App Store" build/AppStore Config/UntilAppStore.entitlements "-D APPSTORE" com.marcovrinssen.until ;;
    run)
        bundle direct build Config/Until.entitlements "" com.marcovrinssen.until.direct
        pkill -x Until 2>/dev/null || true
        open build/Until.app
        ;;
    *) bundle direct build Config/Until.entitlements "" com.marcovrinssen.until.direct ;;
esac
