#!/usr/bin/env bash
# Install the iOS-on-Linux toolchain on Linux Mint 22.x (Ubuntu 24.04 base).
# Safe to re-run: completed pieces are skipped. System dependencies come from
# apt; downloaded tools and caches live in user paths unless noted otherwise.
#
# Mode (what supplies the iOS build files):
#   --mode full       the SDK from an Xcode download (the default)
#   --mode no-xcode   no Xcode download: link stubs and headers from your iPhone or from Apple's public iOS
#                     update download (sdk-free/README.md)
# The choice also comes from MINT_APPLE_MODE, from ~/.config/mint-apple-dev/mode (the last run), or from a
# prompt when run from a terminal. Without a terminal and without a choice it is full.
set -euo pipefail
PATH="$HOME/.local/bin:$PATH"
export PATH

# Put the active toolchain's own bin dir (clang, lldb) first on PATH. Derive it
# from the swift on PATH because tarball and user-managed installs differ. A system clang of another version
# breaks SwiftUI builds against the SDK (FINDINGS.md item 5).
toolchain_first_on_path() {
  PATH="$(dirname "$(readlink -f "$(command -v swift)")"):$PATH"
  export PATH
}

# Xcode major whose bundled Swift matches the toolchain (FINDINGS.md 16, 22).
matching_xcode() {
  case "$(swift --version 2>/dev/null)" in
    *"Swift version 6.4"*) echo 27 ;;
    *"Swift version 6.3"*) echo 26 ;;
    *) echo "whose Swift matches $(swift --version 2>/dev/null | head -n1)" ;;
  esac
}

VENV="$HOME/pymobile3-venv"
SDK_SRC="${SDK_SRC:-$HOME/xcode-apple-sdk-src}"
SDK_CACHE="${SDK_CACHE:-$HOME/.cache/xtool}"

# Register the SDK bundle at $1 into whatever toolchain is first on PATH.
# swift sdk install refuses to overwrite an existing bundle, so clear it first.
sdk_install_from() {
  swift sdk remove darwin >/dev/null 2>&1 || true
  "$HOME/.local/bin/xtool" sdk install "$1"
}

REPO_DIR=$(dirname "$(readlink -f "$0")")
# SwiftPM keeps Swift SDKs under $XDG_CONFIG_HOME/swiftpm when XDG_CONFIG_HOME is
# set, else under ~/.swiftpm.
DARWIN_SDK_BUNDLE="${XDG_CONFIG_HOME:+$XDG_CONFIG_HOME/swiftpm}"
DARWIN_SDK_BUNDLE="${DARWIN_SDK_BUNDLE:-$HOME/.swiftpm}/swift-sdks/darwin.artifactbundle"

# Shallow-fetch one commit of a repo into a cache dir (kept; the build reuses it).
fetch_commit() { # repo sha dir
  if [ ! -d "$3/.git" ]; then
    git init -q "$3"
    git -C "$3" fetch -q --depth 1 "$1" "$2"
    git -C "$3" checkout -q FETCH_HEAD
  fi
}

require_linux_mint() {
  local os_release=${OS_RELEASE_FILE:-/etc/os-release}
  if [ ! -r "$os_release" ]; then
    echo "Cannot identify this system: $os_release is missing." >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  . "$os_release"
  if [ "${ID:-}" != linuxmint ]; then
    echo "This installer supports Linux Mint 22.x. Detected: ${PRETTY_NAME:-unknown Linux}." >&2
    echo "Use --user-only only after installing compatible dependencies and Swift yourself." >&2
    exit 1
  fi
  case "${VERSION_ID:-}" in
    22 | 22.*) ;;
    *)
      echo "This installer supports Linux Mint 22.x. Detected version: ${VERSION_ID:-unknown}." >&2
      exit 1
      ;;
  esac
  case "$(uname -m)" in
    x86_64) ;;
    aarch64)
      echo "WARNING: Linux Mint on aarch64 is a best-effort community configuration." >&2
      ;;
    *)
      echo "Unsupported CPU architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

install_mint_packages() {
  echo "== 1. Linux Mint build and iPhone USB dependencies =="
  sudo apt-get update
  sudo apt-get install -y \
    autoconf automake binutils build-essential ca-certificates cmake curl file \
    git gnupg2 libc6-dev libbz2-dev libcurl4-openssl-dev libedit2 \
    libfuse3-dev libgcc-13-dev libheif-dev libheif-examples \
    libimobiledevice-dev liblzma-dev libncurses-dev libpython3-dev \
    libsqlite3-0 libssl-dev libstdc++-13-dev libtool libusbmuxd-dev \
    libxml2-dev libz3-dev llvm make pkg-config poppler-utils python3 \
    python3-venv rsync tzdata unzip usbmuxd uuid-dev zip zlib1g-dev
}

SWIFT_VERSION=6.4.0
SWIFT_RELEASE=swift-$SWIFT_VERSION-RELEASE

install_swift() {
  if command -v swift >/dev/null 2>&1 && swift --version 2>/dev/null | grep -q "Swift version $SWIFT_VERSION"; then
    echo "== 2. Swift $SWIFT_VERSION already on PATH =="
    return
  fi

  local platform archive url cache base dest keyring unpack extracted binary
  case "$(uname -m)" in
    x86_64)
      platform=ubuntu2404
      archive="$SWIFT_RELEASE-ubuntu24.04.tar.gz"
      ;;
    aarch64)
      platform=ubuntu2404-aarch64
      archive="$SWIFT_RELEASE-ubuntu24.04-aarch64.tar.gz"
      ;;
  esac
  url="https://download.swift.org/swift-$SWIFT_VERSION-release/$platform/$SWIFT_RELEASE/$archive"
  cache="$HOME/.cache/mint-apple-dev/swift-$SWIFT_VERSION"
  base="$HOME/.local/share/swift"
  dest="$base/$SWIFT_RELEASE-ubuntu24.04-$(uname -m)"
  mkdir -p "$cache" "$base" "$HOME/.local/bin"

  echo "== 2. Official Swift $SWIFT_VERSION toolchain =="
  if [ ! -s "$cache/$archive" ]; then
    curl -fL --retry 3 "$url" -o "$cache/$archive"
  fi
  curl -fL --retry 3 "$url.sig" -o "$cache/$archive.sig"
  curl -fL --retry 3 https://swift.org/keys/all-keys.asc -o "$cache/swift-keys.asc"

  keyring=$(mktemp -d)
  chmod 700 "$keyring"
  GNUPGHOME="$keyring" gpg --batch --import "$cache/swift-keys.asc" >/dev/null 2>&1
  GNUPGHOME="$keyring" gpg --batch --verify "$cache/$archive.sig" "$cache/$archive"
  rm -rf "$keyring"

  if [ ! -x "$dest/usr/bin/swift" ]; then
    if [ -e "$dest" ]; then
      echo "Incomplete Swift destination exists: $dest" >&2
      echo "Move it aside and rerun the installer." >&2
      exit 1
    fi
    unpack=$(mktemp -d "$base/.unpack.XXXXXX")
    tar -xzf "$cache/$archive" -C "$unpack"
    extracted=
    for binary in "$unpack" "$unpack"/*; do
      if [ -x "$binary/usr/bin/swift" ]; then extracted=$binary; break; fi
    done
    if [ -z "$extracted" ]; then
      echo "The verified Swift archive did not contain usr/bin/swift." >&2
      exit 1
    fi
    mv "$extracted" "$dest"
    [ "$extracted" = "$unpack" ] || rm -rf "$unpack"
  fi

  for binary in "$dest/usr/bin/"*; do
    [ -f "$binary" ] && [ -x "$binary" ] || continue
    ln -sfn "$binary" "$HOME/.local/bin/$(basename "$binary")"
  done
  PATH="$HOME/.local/bin:$PATH"
  export PATH
  swift --version | head -n1
}

libimobiledevice_has_event_api() {
  pkg-config --exists libimobiledevice-1.0 || return 1
  printf '%s\n' '#include <libimobiledevice/libimobiledevice.h>' \
    'int main(void) { (void)idevice_events_subscribe; return 0; }' |
    cc $(pkg-config --cflags libimobiledevice-1.0) -x c -fsyntax-only - >/dev/null 2>&1
}

install_current_libimobiledevice() {
  if libimobiledevice_has_event_api; then
    echo "== 2b. libimobiledevice already provides the xtool event API =="
    return
  fi

  echo "== 2b. Current libimobiledevice stack (Mint's package API is too old) =="
  local cache="$HOME/.cache/mint-apple-dev/libimobiledevice"
  local jobs
  jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
  mkdir -p "$cache"
  export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

  build_component() { # name repo sha [configure args...]
    local name=$1 repo=$2 sha=$3 src
    shift 3
    src="$cache/$name-$sha"
    fetch_commit "$repo" "$sha" "$src"
    echo "Building $name at $sha"
    (cd "$src" && ./autogen.sh --prefix=/usr/local --disable-static "$@" && make -j"$jobs")
    sudo make -C "$src" install
    sudo ldconfig
  }

  build_component libplist https://github.com/libimobiledevice/libplist.git \
    fe3dc34dc3484006e12b403f7ceb06f0ad40b6f4 --without-cython
  build_component libimobiledevice-glue https://github.com/libimobiledevice/libimobiledevice-glue.git \
    aef2bf0f5bfe961ad83d224166462d87b1df2b00
  build_component libtatsu https://github.com/libimobiledevice/libtatsu.git \
    42329cb756682535c7c0f087987b78d1dd5b16c8
  build_component libimobiledevice https://github.com/libimobiledevice/libimobiledevice.git \
    149f7623c672c1fa73122c7119a12bfc0012f2ac --without-cython

  if ! libimobiledevice_has_event_api; then
    echo "The source-built libimobiledevice does not expose idevice_events_subscribe." >&2
    exit 1
  fi
}

# xtool 1.20.1 plus fixes not released yet (xtool-org/xtool#290-#293, #295, #302): branch-pinned
# dependencies, `type: .dynamic` package products, extension dylibs kept in the host app
# (FINDINGS.md 24.1, 27.3, 30), and real source paths for SourceKit-LSP (FINDINGS.md 55).
# Built from source with its Swift runtime libraries next to it
# ($ORIGIN only), so a toolchain swap or upgrade cannot break it.
XTOOL_REPO=https://github.com/joshuaswarren/xtool
XTOOL_SHA=f0a1f90efdbb0dc023e276ff529da92618da7a87
install_xtool() {
  local src="$HOME/.cache/mint-apple-dev/xtool-$XTOOL_SHA"
  local dest="$HOME/.local/lib/mint-apple-dev/xtool-$XTOOL_SHA"
  if [ ! -x "$dest/xtool" ]; then
    fetch_commit "$XTOOL_REPO" "$XTOOL_SHA" "$src"
    echo "Building xtool $XTOOL_SHA (first run: about 7 minutes)"
    (cd "$src" && swift build -c release --product xtool -Xswiftc -no-toolchain-stdlib-rpath >/dev/null)
    local bin runtime
    bin=$(cd "$src" && swift build -c release --show-bin-path)
    runtime="$(dirname "$(dirname "$(readlink -f "$(command -v swift)")")")/lib/swift/linux"
    mkdir -p "$dest"
    install -m755 "$bin/xtool" "$bin/libXADI.so" "$dest/"
    LD_LIBRARY_PATH="$runtime" ldd "$dest/xtool" | awk -v rt="$runtime/" 'index($3, rt) == 1 { print $3 }' |
      xargs -r install -m644 -t "$dest"
  fi
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$dest/xtool" "$HOME/.local/bin/xtool"
}

# xtool's SDK ships OpenAppleMacros v1.3.0 as the Darwin macro plugin server; it has no
# SwiftData macros, no widget #Preview (PreviewsMacros.Common), and the toolchain's own
# FoundationMacros emit `FoundationEssentials.` (#Predicate fails). Build the fork that adds
# them and register its modules with empty plugin stubs, which outrank the toolchain plugins.
# FINDINGS.md 26, 31.
OAM_REPO=https://github.com/joshuaswarren/OpenAppleMacros
OAM_SHA=cb003a1763b08947dd37376ed8240cbfb4745c32
install_oam() {
  local src="$HOME/.cache/mint-apple-dev/oam-$OAM_SHA"
  local plugins="$DARWIN_SDK_BUNDLE/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins"
  fetch_commit "$OAM_REPO" "$OAM_SHA" "$src"
  echo "Building OpenAppleMacrosServer $OAM_SHA (first run: about 5 minutes)"
  (cd "$src" && swift build -c release --build-system native --static-swift-stdlib \
    --product OpenAppleMacrosServer >/dev/null)
  install -m755 "$src/.build/release/OpenAppleMacrosServer" "$DARWIN_SDK_BUNDLE/OpenAppleMacrosServer"
  : > "$plugins/libSwiftDataMacros.so"
  : > "$plugins/libFoundationMacros.so"
}

# SwiftBuild (xtool 1.20 on Swift 6.4) runs actool for .xcassets and xcstringstool
# for .xcstrings package resources, and looks for both in the iPhoneOS platform's
# Developer/usr/bin. Install the Linux stand-ins there, give .strings copies an
# input encoding (SwiftBuild detects encodings only on macOS), and turn on Swift
# cross-import overlays (StoreKit + SwiftUI = StoreView, ...). FINDINGS.md 24.
# Dylib links of `type: .dynamic` products need the Swift runtime (-L/usr/lib/swift
# resolves under ld64's -syslibroot, the iPhoneOS SDK) and -all_load (SwiftPM builds
# their modules as archives). FINDINGS.md 27.3; also in xtool-org/xtool#293.
install_darwin_tools() {
  local bin="$DARWIN_SDK_BUNDLE/Developer/Platforms/iPhoneOS.platform/Developer/usr/bin"
  (cd "$REPO_DIR/tools/darwin-tools" && swift build -c release --product actool >/dev/null)
  mkdir -p "$bin"
  install -m755 "$REPO_DIR/tools/darwin-tools/.build/release/actool" "$bin/actool"
  install -m755 "$REPO_DIR/tools/xcstringstool" "$REPO_DIR/tools/ibtool" "$bin/"
  install -m644 "$REPO_DIR/tools/nibarchive.py" "$REPO_DIR/tools/keyorder.py" "$bin/"
  install -m755 "$REPO_DIR/tools/momc" "$bin/momc"
  install -m644 "$REPO_DIR/tools/xcstrings_symbols.py" "$bin/xcstrings_symbols.py"
  # macOS builds (swiftbuild --triple arm64-apple-macosx) look in the MacOSX
  # platform's Developer/usr/bin instead.
  local macbin="$DARWIN_SDK_BUNDLE/Developer/Platforms/MacOSX.platform/Developer/usr/bin"
  mkdir -p "$macbin"
  install -m755 "$REPO_DIR/tools/darwin-tools/.build/release/actool" "$macbin/actool"
  install -m755 "$REPO_DIR/tools/xcstringstool" "$REPO_DIR/tools/ibtool" "$macbin/"
  # The Mac nib compiler: the SDK ibtool dispatches MacOSX.Cocoa xibs to the
  # ibmac module and imports it from its own directory (SwiftBuild does not
  # pass PYTHONPATH through to build tasks).
  install -m644 "$REPO_DIR/tools/ibmac.py" "$macbin/"
  install -m644 "$REPO_DIR/tools/nibarchive.py" "$REPO_DIR/tools/keyorder.py" "$macbin/"
  install -m755 "$REPO_DIR/tools/momc" "$macbin/momc"
  install -m644 "$REPO_DIR/tools/xcstrings_symbols.py" "$macbin/xcstrings_symbols.py"
  python3 - "$DARWIN_SDK_BUNDLE" <<'PY'
import json, os, plistlib, sys
bundle = sys.argv[1]
for platform_name in ("iPhoneOS.platform", "MacOSX.platform"):
    platform = os.path.join(bundle, "Developer/Platforms", platform_name, "Info.plist")
    if not os.path.isfile(platform):
        continue
    with open(platform, "rb") as f:
        plist = plistlib.load(f)
    plist.setdefault("DefaultProperties", {})["STRINGS_FILE_INPUT_ENCODING"] = "utf-8"
    with open(platform + ".tmp", "wb") as f:
        plistlib.dump(plist, f)
    os.replace(platform + ".tmp", platform)
toolset = os.path.join(bundle, "toolset-swb.json")
with open(toolset) as f:
    data = json.load(f)
data.setdefault("swiftCompiler", {})["extraCLIOptions"] = ["-Xfrontend", "-enable-cross-import-overlays"]
data.setdefault("linker", {})["extraCLIOptions"] = ["-lswiftCore", "-L/usr/lib/swift", "-all_load"]
with open(toolset + ".tmp", "w") as f:
    json.dump(data, f, indent=4)
os.replace(toolset + ".tmp", toolset)
# Linux has no `tapi`, so swift-build cannot generate eager-linking stubs for
# promoted dylibs; its non-Darwin platforms hardcode the same DefaultProperties.
for platform_name in ("iPhoneOS.platform", "MacOSX.platform"):
    sdks = os.path.join(bundle, "Developer/Platforms", platform_name, "Developer/SDKs")
    for sdk in sorted(os.listdir(sdks)) if os.path.isdir(sdks) else []:
        if os.path.islink(os.path.join(sdks, sdk)):
            continue
        p = os.path.join(sdks, sdk, "SDKSettings.json")
        if os.path.isfile(p):
            d = json.load(open(p))
            dp = d.setdefault("DefaultProperties", {})
            dp["STRINGS_FILE_INPUT_ENCODING"] = "utf-8"
            dp["STRINGS_FILE_OUTPUT_ENCODING"] = "binary"
            dp.setdefault("GENERATE_INTERMEDIATE_TEXT_BASED_STUBS", "NO")
            dp.setdefault("GENERATE_TEXT_BASED_STUBS", "NO")
            json.dump(d, open(p, "w"))
        p = os.path.join(sdks, sdk, "SDKSettings.plist")
        d = plistlib.load(open(p, "rb")) if os.path.isfile(p) else {"DefaultProperties": {}}
        dp = d.setdefault("DefaultProperties", {})
        if dp.get("GENERATE_INTERMEDIATE_TEXT_BASED_STUBS") == "NO":
            continue
        dp["GENERATE_INTERMEDIATE_TEXT_BASED_STUBS"] = "NO"
        dp["GENERATE_TEXT_BASED_STUBS"] = "NO"
        plistlib.dump(d, open(p + ".tmp", "wb"))
        os.replace(p + ".tmp", p)
# The CopyStrings task cannot re-encode strings outside Darwin:
# FileTextEncoding.stringEncoding is `#if canImport(Darwin)`. Only the binary
# plist output works on Linux, and the input encoding must be spelled out
# (BOM detection sees only UTF-8/16 BOMs). Patch the spec defaults.
import re, shutil
swift_bin = shutil.which("swift")
if not swift_bin:
    sys.exit("install_darwin_tools: swift not on PATH")
# realpath ends in usr/bin/<driver>; the toolchain root is everything before
# that usr/bin (may be a plain prefix, not exactly four levels up).
toolchain_root = re.sub(r"/usr/bin/[^/]+$", "",
                        os.path.realpath(swift_bin))
for rel, fixes in (
    ("usr/share/pm/SwiftBuild_SWBUniversalPlatform.bundle/CopyStringsFile.xcspec",
     [("STRINGS_FILE_INPUT_ENCODING", "utf-8")]),
    ("usr/share/pm/SwiftBuild_SWBCore.bundle/CoreBuildSystem.xcspec",
     [("STRINGS_FILE_OUTPUT_ENCODING", "binary")]),
    ("usr/share/pm/SwiftBuild_SWBCore.bundle/NativeBuildSystem.xcspec",
     [("STRINGS_FILE_OUTPUT_ENCODING", "binary")]),
):
    p = os.path.join(toolchain_root, rel)
    if not os.path.isfile(p):
        continue
    old = open(p).read()
    lines = old.split("\n")
    for setting, value in fixes:
        for i, line in enumerate(lines):
            if f'Name = "{setting}";' in line or f'Name = {setting};' in line:
                for j in range(i + 1, min(i + 12, len(lines))):
                    if "DefaultValue =" in lines[j]:
                        lines[j] = re.sub(r'"[^"]*"\s*;', f'"{value}";', lines[j])
                        break
    new = "\n".join(lines)
    if new == old:
        continue
    # A system-managed toolchain can be root-owned: say what to patch instead
    # of aborting the rest of the install.
    if not os.access(p, os.W_OK):
        print(f"WARNING: {p} is not writable; set its {', '.join(s for s, _ in fixes)} "
              f"DefaultValue to {', '.join(v for _, v in fixes)} as root", file=sys.stderr)
        continue
    open(p, "w").write(new)
PY
  echo "Installed actool, xcstringstool, momc and ibtool (version probe; compiles a small xib subset) into $bin"
}

# Build the portable darwin.xtoolsdk from an Xcode.xip or Xcode.app ($1),
# keep it in the cache, and register it. Building instead of installing
# directly costs the same extraction plus one local copy, but the result is
# toolchain-independent: it survives toolchain swaps (mise/asdf/manual) and
# re-registers with no .xip and no network (see README, Toolchain swaps).
sdk_build_and_install() {
  mkdir -p "$SDK_CACHE"
  tmpd=$(mktemp -d "$SDK_CACHE/.build.XXXXXX")
  "$HOME/.local/bin/xtool" sdk build "$1" "$tmpd"
  # Name the cache after the iOS SDK inside it; works for .xip and Xcode.app input.
  ver=unknown
  for sdk in "$tmpd"/darwin.xtoolsdk/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS[0-9]*.sdk; do
    if [ -e "$sdk" ]; then ver=$(basename "$sdk" .sdk); fi
  done
  cached="$SDK_CACHE/darwin-$ver.xtoolsdk"
  rm -rf "$cached"
  mv "$tmpd/darwin.xtoolsdk" "$cached"
  rmdir "$tmpd"
  echo "SDK cache kept at: $cached"
  # ship.sh stamps DTXcode/DTXcodeBuild from this. A .xip hides it; set
  # XCODE_VERSION and XCODE_BUILD for ship.sh instead.
  if [ -f "$1/Contents/version.plist" ]; then cp "$1/Contents/version.plist" "$cached.version.plist"; fi
  # ship.sh trains App Shortcuts (Metadata.appintents/nlu) with Xcode's phrase lists from here. A
  # .xip hides them too; set SSU_RESOURCES for ship.sh to a copy of this directory instead.
  ssu_src="$1/Contents/Frameworks/SiriSSUKitModel.framework/Versions/A/Resources"
  if [ -d "$ssu_src" ]; then rm -rf "$cached.SiriSSUKitModel"; cp -R "$ssu_src" "$cached.SiriSSUKitModel"; fi
  sdk_install_from "$cached"
}

# Survive-status summary: what a toolchain swap leaves behind.
survive_status() {
  echo "-- Survive status --"
  echo "SDK: re-registered from $1"
  if ls "$HOME/.pymobiledevice3"/*.plist >/dev/null 2>&1; then
    echo "pairing: intact at $HOME/.pymobiledevice3"
  else
    echo "pairing: no records yet (plug the iPhone once; nothing is lost here by a swap)"
  fi
  if [ -n "$(ls -A "$HOME/.local/share/xtool" 2>/dev/null)" ]; then
    echo "auth: present at $HOME/.local/share/xtool"
  else
    echo "auth: missing — run: $HOME/.local/bin/xtool auth"
  fi
}

# Install mode: --mode, MINT_APPLE_MODE, the saved choice, or a prompt.
MODE_FILE=$HOME/.config/mint-apple-dev/mode
MODE=${MINT_APPLE_MODE:-}
mode_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE=${2:?--mode needs full or no-xcode}; shift 2 ;;
    --mode=*) MODE=${1#--mode=}; shift ;;
    *) mode_args+=("$1"); shift ;;
  esac
done
set -- "${mode_args[@]+"${mode_args[@]}"}"

print_modes() {
  cat <<'EOF'

How should this install get the iOS build files?

  1) full (Xcode download)
     Works:      Swift, SwiftUI, Objective-C, C and C++; every system framework; app extensions and widgets;
                 Flutter apps; macOS apps; TestFlight and App Store uploads with a paid account.
     Needs:      the Xcode archive from Apple (about 3 GB of it is used) and a free Apple ID to download it.

  2) no Xcode download (experimental)
     Works:      Objective-C and C apps with UIKit; Swift (standard library, async/await, Foundation); Flutter
                 apps (release builds) with an Objective-C runner, Objective-C plugins and the Swift plugins
                 shared_preferences and url_launcher; a small SwiftUI subset; asset catalogs and storyboards;
                 install on your iPhone with a free Apple ID; TestFlight upload of Flutter apps with a paid account.
     Not yet:    most of SwiftUI; the full set of system frameworks (the list grows by release); app extensions and
                 widgets; macOS apps.
     Needs:      an iPhone only to run the apps. Setup needs no phone: it copies the cache from a connected iPhone
                 or pulls it from Apple's public iOS update download; about 7 GB of temporary disk.

EOF
}

resolve_mode() {
  if [ -z "$MODE" ] && [ -f "$MODE_FILE" ]; then MODE=$(cat "$MODE_FILE"); fi
  if [ -z "$MODE" ] && [ -t 0 ] && [ -t 1 ]; then
    print_modes
    while :; do
      read -r -p "Choose 1 or 2 [1]: " answer
      case "${answer:-1}" in
        1) MODE=full; break ;;
        2) MODE=no-xcode; break ;;
      esac
    done
  fi
  MODE=${MODE:-full}
  case "$MODE" in
    full | no-xcode) ;;
    *) echo "Unknown mode '$MODE': use full or no-xcode" >&2; exit 2 ;;
  esac
  mkdir -p "$(dirname "$MODE_FILE")"
  printf '%s\n' "$MODE" >"$MODE_FILE"
  echo "== Mode: $MODE"
}

if [ "${1:-}" = "--mode-help" ]; then
  print_modes
  exit 0
fi

if [ "${1:-}" = "--repair" ]; then
  # Toolchain swapped out from under a working setup (mise, asdf, manual
  # reinstall): repair runs against whatever toolchain the current shell
  # resolves, so the SDK is re-registered into THAT toolchain. Pairing and
  # Apple ID auth live in user-global paths and were never affected.
  if [ "$MODE" = no-xcode ] || { [ -z "$MODE" ] && [ "$(cat "$MODE_FILE" 2>/dev/null || true)" = no-xcode ]; }; then
    echo "Mode no-xcode: rebuilding the sysroot (from a connected iPhone, or Apple's public iOS update download)"
    exec "$REPO_DIR/sdk-free/setup.sh"
  fi
  if ! command -v swift >/dev/null 2>&1; then
    echo "No swift on PATH. Activate your toolchain first — for mise:"
    echo '  eval "$(mise activate bash)"   # or reopen your shell'
    exit 1
  fi
  swift --version | head -n1
  toolchain_first_on_path
  cached=$(ls -dt "$SDK_CACHE"/darwin-*.xtoolsdk 2>/dev/null | head -n1 || true)
  if [ -n "$cached" ]; then
    sdk_install_from "$cached"
  elif [ -n "${XCODE_XIP:-}" ] && [ -f "$XCODE_XIP" ]; then
    cached="XCODE_XIP=$XCODE_XIP"
    sdk_build_and_install "$XCODE_XIP"
  else
    echo "No cached SDK in $SDK_CACHE and no XCODE_XIP given."
    echo "Nothing to repair from. Either point XCODE_XIP at an Xcode $(matching_xcode) .xip,"
    echo "or run once with XCODE_XIP to build the cache for next time."
    exit 1
  fi
  swift sdk list   # must print: darwin
  install_darwin_tools
  install_oam
  survive_status "$cached"
  exit 0
fi

resolve_mode

# --user-only: no sudo and no system packages. Bring a compatible Swift 6.4
# toolchain and the system tools listed in docs/DISTROS.md.
warn_user_tools() {
  for tool in zip python3 git cc pkg-config pdftocairo heif-convert; do
    command -v "$tool" >/dev/null || echo "WARNING: $tool is missing; ask an admin for it"
  done
  pkg-config --exists libimobiledevice-1.0 openssl ||
    echo "WARNING: libimobiledevice or openssl headers are missing (xtool build); ask an admin for them"
  # lldb links one libpython3.x (3.12 for Swift 6.4); device-run.sh --lldb needs it.
  lldb_missing=$(ldd "$(dirname "$(readlink -f "$(command -v swift)")")/../lib/liblldb.so"* 2>/dev/null |
    awk '/not found/ {print $1}' | sort -u)
  if [ -n "$lldb_missing" ]; then echo "WARNING: lldb needs $lldb_missing; ask an admin for it"; fi
}

if [ "${1:-}" = "--user-only" ]; then
  echo "== 1-2. User-only install: using $(command -v swift || echo 'no swift on PATH')"
  if ! command -v swift >/dev/null 2>&1; then
    echo "Swift 6.4 is required on PATH for --user-only." >&2
    exit 1
  fi
  if ! swift --version 2>/dev/null | grep -q "Swift version $SWIFT_VERSION"; then
    echo "--user-only requires Swift $SWIFT_VERSION; found: $(swift --version 2>/dev/null | head -n1)" >&2
    exit 1
  fi
  swift --version | head -n1
  warn_user_tools
else
  require_linux_mint
  install_mint_packages
  install_swift
  install_current_libimobiledevice
fi

echo "== 3. xtool (built from source) and rcodesign (aarch64 and x86_64 releases) =="
toolchain_first_on_path
install_xtool
"$HOME/.local/bin/xtool" --version
# rcodesign (apple-codesign) signs App Store builds for ship.sh; pinned + checksummed.
RCODESIGN_VERSION=0.29.0
case "$(uname -m)" in
  aarch64) rcs_sha=4af92c87ddf52f5f2d1258a3b4e56c7dcb8f1b2468df744976c5f139e031961f ;;
  x86_64) rcs_sha=dbe85cedd8ee4217b64e9a0e4c2aef92ab8bcaaa41f20bde99781ff02e600002 ;;
esac
if ! "$HOME/.local/bin/rcodesign" --version 2>/dev/null | grep -q "$RCODESIGN_VERSION"; then
  rcs=apple-codesign-$RCODESIGN_VERSION-$(uname -m)-unknown-linux-musl
  rcs_tmp=$(mktemp -d)
  curl -fsSL "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F$RCODESIGN_VERSION/$rcs.tar.gz" \
    -o "$rcs_tmp/rcs.tar.gz"
  echo "$rcs_sha  $rcs_tmp/rcs.tar.gz" | sha256sum -c --quiet
  tar -xzf "$rcs_tmp/rcs.tar.gz" -C "$rcs_tmp"
  install -m755 "$rcs_tmp/$rcs/rcodesign" "$HOME/.local/bin/rcodesign"
  rm -rf "$rcs_tmp"
fi
"$HOME/.local/bin/rcodesign" --version
# ipsw extracts the Swift runtime dylibs from an iPhone's shared cache for LLDB (device-run.sh
# --lldb, FINDINGS.md 56); pinned + checksummed.
IPSW_VERSION=3.1.731
case "$(uname -m)" in
  aarch64) ipsw_arch=arm64 ipsw_sha=a8d373966d79d24537aa17ec8b9a61bbc73964e6200383f7708c53400ad9f42a ;;
  x86_64) ipsw_arch=x86_64 ipsw_sha=98e5b127641be3511242a5ba9c5872ef34010e5171318b616e5aa80a607749ff ;;
esac
if ! "$HOME/.local/bin/ipsw" version 2>/dev/null | grep -q "$IPSW_VERSION"; then
  ipsw_tmp=$(mktemp -d)
  curl -fsSL "https://github.com/blacktop/ipsw/releases/download/v$IPSW_VERSION/ipsw_${IPSW_VERSION}_linux_$ipsw_arch.tar.gz" \
    -o "$ipsw_tmp/ipsw.tar.gz"
  echo "$ipsw_sha  $ipsw_tmp/ipsw.tar.gz" | sha256sum -c --quiet
  tar -xzf "$ipsw_tmp/ipsw.tar.gz" -C "$ipsw_tmp" ipsw
  install -m755 "$ipsw_tmp/ipsw" "$HOME/.local/bin/ipsw"
  rm -rf "$ipsw_tmp"
fi
"$HOME/.local/bin/ipsw" version | head -n1

echo "== 4. pymobiledevice3 in a venv =="
python3 -m venv "$VENV"
"$VENV/bin/pip" install pymobiledevice3
"$VENV/bin/pip" show pymobiledevice3 | sed -n 's/^Version: /pymobiledevice3 /p'

if [ "$MODE" = no-xcode ]; then
  echo "== 5. Build files, no Xcode download (iPhone or Apple's public iOS update)"
  "$REPO_DIR/sdk-free/setup.sh"
  echo "== 5b. Swift standard library for iOS, built from source (about 4 minutes)"
  toolchain_first_on_path
  "$REPO_DIR/sdk-free/swift/build-stdlib.sh"
  echo "== 5c. Swift framework overlays for iOS"
  "$REPO_DIR/sdk-free/swift/overlays.sh"
  echo "== 6. Apple ID sign-in (interactive, needed before device deploys)"
  echo "Run: $HOME/.local/bin/xtool auth"
  echo "Done. Next: sdk-free/README.md (Flutter: flutter/setup.sh, then sdk-free/flutter-build.sh <app dir>)"
  exit 0
fi

echo "== 5. iOS SDK source =="
# The SDK artifacts exist only inside Apple's Xcode distribution; there is no
# standalone iOS SDK download. The public route needs no Mac and no macOS
# anywhere: download Xcode.xip from Apple on any OS, hand the file to this
# script. (An already-extracted Xcode.app tree also works via SDK_SRC.)
echo "-- Route A (default): Xcode.xip downloaded from Apple --"
# 1. Sign in at https://developer.apple.com/download/all/?q=Xcode (free Apple ID)
# 2. Download the Xcode .xip whose Swift matches the host toolchain: Xcode 27 for 6.4,
#    Xcode 26 for 6.3 (FINDINGS.md items 16 and 22)
# 3. Re-run:  XCODE_XIP=/path/to/Xcode.xip $0

echo "-- Route B (optional): an extracted Xcode.app tree --"
# If you already have a Mac with a matching Xcode, only these pieces are
# needed (about 3 GB) in $SDK_SRC/Xcode.app/Contents (xtool 1.20 SDKBuilder):
#   ssh MAC_HOST 'cd /Applications/Xcode.app/Contents && tar -cf - \
#     Info.plist version.plist \
#     Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift \
#     Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift_static \
#     Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang \
#     Developer/Platforms/iPhoneOS.platform/Info.plist \
#     Developer/Platforms/iPhoneOS.platform/Developer/SDKs \
#     Developer/Platforms/iPhoneOS.platform/Developer/Library \
#     Developer/Platforms/iPhoneOS.platform/Developer/usr/lib \
#     Developer/Platforms/MacOSX.platform/Info.plist \
#     Developer/Platforms/MacOSX.platform/Developer/SDKs \
#     Developer/Platforms/MacOSX.platform/Developer/Library \
#     Developer/Platforms/MacOSX.platform/Developer/usr/lib \
#     Developer/Platforms/iPhoneSimulator.platform/Info.plist \
#     Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs \
#     Developer/Platforms/iPhoneSimulator.platform/Developer/Library \
#     Developer/Platforms/iPhoneSimulator.platform/Developer/usr/lib' \
#   | tar -xf - -C "$SDK_SRC/Xcode.app/Contents"

echo "== 6. Darwin SDK registration =="
toolchain_first_on_path
if swift sdk list 2>/dev/null | grep -q darwin; then
  echo "Darwin SDK already registered; skipping install."
elif [ -n "${XCODE_XIP:-}" ] && [ -f "$XCODE_XIP" ]; then
  sdk_build_and_install "$XCODE_XIP"
elif [ -d "$SDK_SRC/Xcode.app" ]; then
  sdk_build_and_install "$SDK_SRC/Xcode.app"
else
  echo
  echo "==================================================================="
  echo " One download left: the iOS SDK comes from Apple, inside Xcode.xip."
  echo " No Mac needed — the download works from any OS with a browser."
  echo
  echo " 1. Sign in (free Apple ID):"
  echo "      https://developer.apple.com/download/all/?q=Xcode"
  echo " 2. Download Xcode $(matching_xcode) (.xip). The SDK's Swift must match"
  echo "      the installed Swift toolchain (FINDINGS.md items 16 and 22)."
  echo " 3. Re-run:"
  echo "      XCODE_XIP=/path/to/Xcode.xip $0"
  echo
  echo " Already installed before with this script? The SDK cache in"
  echo " $SDK_CACHE may still have the bundle — try: $0 --repair"
  echo "==================================================================="
  exit 1
fi
swift sdk list   # must print: darwin
install_darwin_tools
install_oam

# If an app that failed against an earlier or broken SDK still fails now, the
# stale module cache is the cause: delete that project's .build directory (or
# build in a fresh copy of the project) and rebuild.

echo "== 7. Apple ID sign-in (interactive, needed before device deploys) =="
echo "Run: $HOME/.local/bin/xtool auth"
echo "Done. Next: plug in the iPhone and run ./device-run.sh"
