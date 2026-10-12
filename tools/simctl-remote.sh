#!/usr/bin/env bash
# Build an xtool-style SwiftPM iOS app for the simulator on Linux Mint, then
# install, launch, and screenshot it in a Mac's Simulator over SSH.
#
#   tools/simctl-remote.sh [app-dir]
#
# Environment:
#   SIM_MAC        Mac SSH target, required (for example user@mac)
#   SIM_DEVICE     simulator name (default "iPhone 17 Pro")
#   SIM_BUNDLE_ID  bundle identifier (default: xtool.yml bundleID)
#   SIM_OUT        screenshot path (default /tmp/<name>-sim.png)
#   DEPLOY_TARGET  iOS deployment target (default 17.0)
set -euo pipefail

SIM_MAC=${SIM_MAC:?set SIM_MAC to a Mac with Xcode, for example user@mac}
SIM_DEVICE=${SIM_DEVICE:-iPhone 17 Pro}
src=$(readlink -f "${1:-apps/HelloMint}")
[ -f "$src/Package.swift" ] || { echo "No Package.swift in $src" >&2; exit 1; }
[ -d "$src/Sources" ] || { echo "No Sources directory in $src" >&2; exit 1; }

name=$(basename "$src")
dt=${DEPLOY_TARGET:-17.0}
stage=/tmp/mint-ios-simulator-$name
out=${SIM_OUT:-/tmp/$name-sim.png}
bid=${SIM_BUNDLE_ID:-$(awk '/^bundleID:/{print $2}' "$src/xtool.yml" 2>/dev/null || true)}
: "${bid:?no bundle id: set SIM_BUNDLE_ID or add xtool.yml to the app}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -a "$src/Package.swift" "$src/Sources" "$work/"
[ -f "$src/xtool.yml" ] && cp -a "$src/xtool.yml" "$work/"

cd "$work"
sdk_bundle=${XDG_CONFIG_HOME:+$XDG_CONFIG_HOME/swiftpm}
sdk_bundle=${sdk_bundle:-$HOME/.swiftpm}/swift-sdks/darwin.artifactbundle
export XCODE_EXTRA_PLATFORM_FOLDERS="$sdk_bundle/Developer/Platforms"
PATH="$sdk_bundle/toolset/bin:$PATH"
export PATH

swift build -c release --swift-sdk arm64-apple-ios-simulator
sdk=$(find "$sdk_bundle/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs" \
  -maxdepth 1 -name 'iPhoneSimulator*.sdk' -type d | sort | tail -n1)
runtime=$(find "$sdk_bundle/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang" \
  -path '*/lib/darwin' -type d | sort | tail -n1)
swift_bin=$(dirname "$(readlink -f "$(command -v swift)")")

"$swift_bin/clang" -target "arm64-apple-ios$dt-simulator" -isysroot "$sdk" -arch arm64 \
  -fuse-ld="$sdk_bundle/toolset/bin/ld64.lld" -Wl,-adhoc_codesign \
  -Wl,-platform_version,ios-simulator,"$dt",27.0 \
  -L"$sdk/usr/lib/swift" -L"$runtime" -lclang_rt.iossim \
  -o "$work/$name.app.bin" "$work/.build/release/$name.o"

mkdir -p "$work/$name.app"
cp "$work/$name.app.bin" "$work/$name.app/$name"
apply_plist="$work/$name.app/Info.plist"
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict>' \
  "<key>CFBundleExecutable</key><string>$name</string>" \
  "<key>CFBundleIdentifier</key><string>$bid</string>" \
  "<key>CFBundleName</key><string>$name</string>" \
  '<key>CFBundlePackageType</key><string>APPL</string>' \
  '<key>CFBundleShortVersionString</key><string>1.0</string>' \
  '<key>CFBundleVersion</key><string>1</string>' \
  '<key>LSRequiresIPhoneOS</key><true/>' \
  '<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>' \
  '<key>UILaunchScreen</key><dict/>' \
  '</dict></plist>' >"$apply_plist"
printf 'APPL?????' >"$work/$name.app/PkgInfo"
tar -czf "$work/$name-sim.tgz" -C "$work" "$name.app"

ssh "$SIM_MAC" "mkdir -p '$stage'"
scp -q "$work/$name-sim.tgz" "$SIM_MAC:$stage/"
ssh "$SIM_MAC" bash -s <<REMOTE
set -euo pipefail
cd '$stage'
tar -xzf '$name-sim.tgz'
xcrun simctl boot '$SIM_DEVICE' 2>/dev/null || true
xcrun simctl install booted '$stage/$name.app'
pid=\$(xcrun simctl launch booted '$bid' | awk '{print \$2}')
sleep 3
xcrun simctl io booted screenshot '$stage/$name-sim.png' >/dev/null
echo "launched pid \$pid"
REMOTE
scp -q "$SIM_MAC:$stage/$name-sim.png" "$out"
echo "screenshot: $out"
