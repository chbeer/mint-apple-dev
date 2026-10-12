# Getting started on Linux Mint 22.x

This walkthrough takes a fresh Linux Mint installation to an iPhone build and,
optionally, a TestFlight upload.

## 1. Install the toolchain

Open a terminal in the repository and run:

```sh
./install-toolchain.sh
```

The installer checks that the host is Linux Mint 22.x, installs the required
`apt` packages, verifies the official Swift 6.4.0 archive, builds xtool, and
sets up the iPhone communication tools.

In full mode it stops once to request Xcode 27. Download the `.xip` with a free
Apple ID from Apple's developer downloads page, then continue:

```sh
XCODE_XIP="$HOME/Downloads/Xcode_27.0.xip" ./install-toolchain.sh
```

When setup completes:

```sh
export PATH="$HOME/.local/bin:$PATH"
swift --version
xtool --version
swift sdk list
```

The last command should list `darwin`.

## 2. Build an app

Create a project:

```sh
xtool new MyApp
cd MyApp
xtool dev build
```

The app bundle is written to `xtool/MyApp.app`.

For an existing Xcode project:

```sh
python3 /path/to/mint-apple-dev/tools/xcodeproj2xtool.py MyApp.xcodeproj
cd mint-xtool
ulimit -n 65536
xtool dev build
```

Read every warning from the adapter generator. It identifies project settings
or resources that need manual work.

## 3. Run on an iPhone

Sign in once, connect and unlock the phone, then accept its trust prompt:

```sh
xtool auth
/path/to/mint-apple-dev/device-run.sh
```

For a debugger session:

```sh
/path/to/mint-apple-dev/device-run.sh --lldb
```

The first debugger run can download or extract several gigabytes of device
support files.

## 4. Upload to TestFlight

This step requires a paid Apple Developer membership.

1. In App Store Connect, create a team API key with the App Manager role.
2. Download the `.p8` file and record its Key ID and Issuer ID.
3. Create the app record and bundle ID in App Store Connect.
4. Run from the generated xtool project:

```sh
ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8" \
ASC_ISSUER_ID=<issuer-id> \
ASC_KEY_ID=XXXXXXXXXX \
  /path/to/mint-apple-dev/ship.sh --upload
```

The script prints Apple's processing result. It uploads the build but never
submits it for review.

## If setup fails

- Confirm the system is Linux Mint 22.x with `cat /etc/os-release`.
- Confirm at least 20 GB is free with `df -h`.
- Rerun the same installer command; completed stages are cached.
- After switching Swift toolchains, run `./install-toolchain.sh --repair`.
- See [docs/DISTROS.md](docs/DISTROS.md) for packages and architecture notes.
