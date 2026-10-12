# Linux Mint support notes

## Supported host

The automatic installer targets **Linux Mint 22.x** on `x86_64`. Mint 22 uses
the Ubuntu 24.04 package base, which matches the Swift 6.4.0 Linux toolchain
used by this repository.

The script intentionally refuses a normal system install on another release or
distribution instead of guessing package names. Expert users can bypass system
package management with `--user-only` after arranging compatible dependencies
and Swift themselves.

## Packages installed by the script

```sh
sudo apt-get install -y \
  autoconf automake binutils build-essential ca-certificates cmake curl file \
  git gnupg2 libc6-dev libbz2-dev libcurl4-openssl-dev libedit2 \
  libfuse3-dev libgcc-13-dev libheif-dev libheif-examples \
  libimobiledevice-dev liblzma-dev libncurses-dev libpython3-dev \
  libsqlite3-0 libssl-dev libstdc++-13-dev libtool libusbmuxd-dev \
  libxml2-dev libz3-dev llvm make pkg-config poppler-utils python3 \
  python3-venv rsync tzdata unzip usbmuxd uuid-dev zip zlib1g-dev
```

Mint's packaged libimobiledevice may not provide the event API required by the
pinned xtool revision. The installer checks the installed header. When needed,
it builds pinned releases of libplist, libimobiledevice-glue, libtatsu, and
libimobiledevice into `/usr/local`, then runs `ldconfig`.

## Swift installation

The installer downloads the architecture-appropriate Swift 6.4.0 Ubuntu 24.04
archive and its detached signature from Swift.org. It imports the Swift release
keys into a temporary keyring, verifies the archive, extracts it under
`~/.local/share/swift/`, and links its executables into `~/.local/bin`.

The archive keeps its `usr/` directory. This is important because SwiftPM finds
the runtime by walking up from the compiler to `usr/lib/swift`.

## Architecture

Linux Mint's standard desktop images are x86_64, which is the supported target.
The installer contains the official aarch64 Swift URL mapping so it can be
tested on community ARM images, but that path is best effort and is not claimed
as supported here.

The generated iPhone applications are arm64 regardless of the host CPU.

## Verification status

The Ubuntu 24.04 dependency path and no-Xcode setup were exercised in a clean
container by the source project. This fork adds Mint detection, package
installation, signed Swift installation, and pinned USB-library builds. Its
shell syntax and repository tests are verified here; an end-to-end Mint host,
iPhone, and Apple signing run remains to be performed.

When reporting a result, include:

- Linux Mint version and architecture;
- `swift --version` and `xtool --version`;
- full installer output;
- iPhone and iOS version, if the failure involves a device.
