#!/usr/bin/env bash
# Exercise the installer's host gate without invoking apt or changing the host.
set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
script=$here/../install-toolchain.sh
block=$(mktemp)
tmp=$(mktemp -d)
trap 'rm -f "$block"; rm -rf "$tmp"' EXIT
sed -n '/^require_linux_mint()/,/^}/p' "$script" >"$block"

check_ok() {
  local name=$1 id=$2 version=$3 os_release="$tmp/os-release"
  printf 'ID=%s\nVERSION_ID="%s"\nPRETTY_NAME="fixture"\n' "$id" "$version" >"$os_release"
  if OS_RELEASE_FILE="$os_release" bash -c 'uname() { echo x86_64; }; source "$1"; require_linux_mint' _ "$block" >/dev/null 2>&1; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    return 1
  fi
}

check_fail() {
  local name=$1 id=$2 version=$3 os_release="$tmp/os-release"
  printf 'ID=%s\nVERSION_ID="%s"\nPRETTY_NAME="fixture"\n' "$id" "$version" >"$os_release"
  if OS_RELEASE_FILE="$os_release" bash -c 'uname() { echo x86_64; }; source "$1"; require_linux_mint' _ "$block" >/dev/null 2>&1; then
    echo "FAIL $name: unexpectedly accepted"
    return 1
  fi
  echo "ok   $name -> refused"
}

check_ok "Mint 22" linuxmint 22
check_ok "Mint 22 point release" linuxmint 22.3
check_fail "different distribution" ubuntu 24.04
check_fail "different Mint major" linuxmint 23
