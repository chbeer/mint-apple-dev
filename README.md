# Build and deploy iOS apps on Linux Mint

Build SwiftUI, UIKit, Objective-C, C, C++, and Flutter apps on Linux Mint,
then install them on a physical iPhone over USB. The normal workflow does not
require a Mac or a macOS installation.

This fork targets **Linux Mint 22.x** (the Ubuntu 24.04 package base) on
`x86_64`. The installer uses `apt`, installs the official Swift 6.4.0 Ubuntu
toolchain, builds the current iPhone USB libraries when Mint's packages are too
old for xtool, and installs the remaining tools under your user account.

> Support status: the underlying Ubuntu 24.04 path has been exercised in a
> clean container. The Mint-specific installer and tests in this fork have been
> statically verified, but the complete flow has not been rerun on a physical
> Mint machine and iPhone in this workspace yet.

## Toolchain

| Tool | Version | Installed from |
|---|---:|---|
| Swift | 6.4.0 | signed Swift.org Ubuntu 24.04 archive |
| xtool | pinned source revision | built by the installer |
| libimobiledevice | 1.4.0 | pinned source revision when Mint's package lacks the required API |
| pymobiledevice3 | current PyPI release | isolated Python virtual environment |
| LLDB | 21.0.0 | Swift toolchain |
| iOS SDK | iPhoneOS 27.0 | Xcode 27 archive in full mode |

Version matching matters: Swift 6.4 requires the SDK from Xcode 27. Swift 6.3
requires Xcode 26. The installer reports the expected Xcode major version.

## Requirements

- Linux Mint 22.x on an x86_64 PC.
- Around 20 GB of free disk space for setup and temporary extraction.
- An iPhone and USB data cable for device installation.
- A free Apple ID for device signing and, in full mode, one Xcode archive
  download from Apple's developer site.
- A paid Apple Developer membership only for TestFlight or App Store uploads.

The iOS SDK is Apple software. This project automates extracting and using the
required pieces but does not redistribute them.

## Install

Clone your fork and run the installer:

```sh
git clone <your-fork-url> mint-apple-dev
cd mint-apple-dev
./install-toolchain.sh
```

The default `full` mode installs system dependencies with `apt`, installs and
verifies Swift, builds xtool, and then pauses when it needs the Xcode archive.
Download the requested `.xip` from
<https://developer.apple.com/download/all/?q=Xcode>, then rerun:

```sh
XCODE_XIP="$HOME/Downloads/Xcode_27.0.xip" ./install-toolchain.sh
```

The script is safe to rerun. It caches sources and the extracted SDK, and it
skips completed work. Add the user binary directory to the current shell if it
is not already present:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Verify the installation:

```sh
swift --version
xtool --version
swift sdk list
```

`swift sdk list` should include `darwin` after full-mode setup finishes.

### Experimental mode without an Xcode download

```sh
./install-toolchain.sh --mode no-xcode
```

This mode builds a limited iOS sysroot from a connected iPhone or Apple's
public iOS update files. It supports Objective-C and C UIKit apps, core Swift
features, a small SwiftUI subset, and constrained Flutter builds. It does not
yet provide the full framework set, app extensions, widgets, or macOS apps.
See [sdk-free/README.md](sdk-free/README.md) and
[docs/TEST-MATRIX.md](docs/TEST-MATRIX.md).

### Install without administrator access

An administrator must install the packages listed in
[docs/DISTROS.md](docs/DISTROS.md), and Swift 6.4 must already be on `PATH`.
Then run:

```sh
./install-toolchain.sh --user-only
```

## Build a first app

```sh
xtool auth
xtool new HelloMint
cd HelloMint
xtool dev build
xtool dev run
```

The build output is `xtool/HelloMint.app`. `xtool dev run` signs, installs, and
launches it on the connected iPhone.

From an existing Xcode project, generate an adapter:

```sh
python3 /path/to/mint-apple-dev/tools/xcodeproj2xtool.py MyApp.xcodeproj
cd mint-xtool
ulimit -n 65536
xtool dev build
```

The generator prints warnings for project features it cannot translate. Review
those warnings before shipping. It also creates SourceKit-LSP build-server
metadata for editors that support BSP.

## Device helper and LLDB

From an xtool project directory:

```sh
/path/to/mint-apple-dev/device-run.sh
/path/to/mint-apple-dev/device-run.sh --lldb
```

The first command pairs, installs, and launches. The second also prepares the
developer image and attaches LLDB. USB is the dependable default; wireless
behavior depends on the iOS version and pairing state. Remote iOS 27 operation
is documented in [docs/OVER-TAILNET.md](docs/OVER-TAILNET.md).

## Flutter

The main installer includes LLVM and `rsync`, so Flutter setup needs no extra
system package command:

```sh
flutter/setup.sh
flutter create --platforms ios counter
flutter/build.sh counter
```

The unsigned result is `counter/build/ios-linux/Runner.ipa`. With a free Apple
ID, use `flutter/build.sh --install counter` and let xtool sign and install it.
For a development profile created through App Store Connect:

```sh
tools/provision-dev.py --bundle-id dev.linuxmint.flutterdemo.counter
tools/sign-dev.sh counter/build/ios-linux/Payload/Runner.app Runner-dev.ipa
```

Flutter support is release-only: there is no hot reload or local iOS simulator.
See [flutter/README.md](flutter/README.md).

## TestFlight

Create an App Store Connect API key with the App Manager role and create the app
record in App Store Connect. Then run from the app's xtool project:

```sh
ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8" \
ASC_ISSUER_ID=<issuer-id> \
ASC_KEY_ID=XXXXXXXXXX \
  /path/to/mint-apple-dev/ship.sh --upload
```

The script builds, signs, validates, and uploads the IPA. It does not submit the
build for App Review. Signing material is stored under
`~/.config/mint-apple-dev/`.

## Repair after changing Swift

The extracted iOS SDK cache survives a Swift toolchain replacement, but it must
be registered with the active toolchain again:

```sh
./install-toolchain.sh --repair
```

USB pairing records and Apple ID authentication are stored separately and are
not removed by this repair.

## Troubleshooting

- `Too many open files`: run `ulimit -n 65536` before the build.
- `swift` or `xtool` not found after installation: add `~/.local/bin` to
  `PATH` or start a new login session.
- SDK mismatch errors: use the Xcode major reported by the installer.
- USB discovery problems: reconnect the cable, unlock the phone, accept the
  trust prompt, and confirm that `usbmuxd` is running.
- More system detail: [docs/DISTROS.md](docs/DISTROS.md).
- Known build limitations: [FINDINGS.md](FINDINGS.md).

## License

MIT. See [LICENSE](LICENSE).
