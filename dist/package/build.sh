#!/usr/bin/env bash
# Build Ghostty release packages.
#
#   dist/package/build.sh [dmg|deb|appimage|linux|all]... [options]
#
#   dmg       macOS disk image (must run on macOS, needs Xcode)
#   deb       Debian/Ubuntu package (built in Docker)
#   appimage  Linux AppImage (built in Docker)
#   linux     deb + appimage from a single Linux build
#   all       everything (default on macOS: dmg + linux; elsewhere: linux)
#
# Options:
#   --arch LIST          Linux target architectures: amd64, arm64, a comma
#                        list (amd64,arm64) or all. Default: host arch.
#                        A foreign arch runs under Docker's QEMU emulation
#                        and is much slower.
#   --jobs N             Parallel compile jobs for the Linux build. Default:
#                        all cores natively, 2 under emulation (emulated
#                        compiles use a lot of memory and get OOM-killed).
#   --out DIR            Output directory (default: zig-out/packages)
#   --base-image IMAGE   Linux build image (default: ubuntu:26.04). Must ship
#                        libadwaita >= 1.7 and GTK 4. The .deb and AppImage
#                        only run on distros with a glibc at least as new.
#   --sign IDENTITY      codesign identity for the app and dmg. By default a
#                        "Developer ID Application" identity from your
#                        keychain is used (you're asked to pick if there are
#                        several).
#   --no-sign            Skip signing; the app keeps Xcode's local ad-hoc
#                        signature, so Gatekeeper blocks it on other Macs.
#   --notarize           Notarize and staple the dmg (default: ask when
#                        signed with a Developer ID).
#   --no-notarize        Skip notarization.
#
# Notarization asks for your Apple ID and an app-specific password
# (create one at https://account.apple.com > Sign-In and Security).
# To skip the prompts set any of:
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
#   NOTARY_PROFILE       a profile saved with `xcrun notarytool store-credentials`
#
# Other environment:
#   MACOS_SIGN_IDENTITY  same as --sign
#   DEB_MAINTAINER       Maintainer field of the .deb
#                        (default: git user.name <user.email>)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OUT_DIR="$REPO_ROOT/zig-out/packages"
BASE_IMAGE="ubuntu:26.04"
ARCH_ARG=""
ARCHES=()
JOBS=""
TARGETS=()
SIGN_IDENTITY="${MACOS_SIGN_IDENTITY:-}"
SIGN=auto       # auto | yes | no
NOTARIZE=auto   # auto | yes | no

die() { echo "error: $*" >&2; exit 1; }
log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
interactive() { [[ -t 0 ]]; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    dmg | deb | appimage | linux | all) TARGETS+=("$1") ;;
    --arch) ARCH_ARG="${2:?--arch needs a value}"; shift ;;
    --jobs) JOBS="${2:?--jobs needs a value}"; shift ;;
    --out) OUT_DIR="${2:?--out needs a value}"; shift ;;
    --base-image) BASE_IMAGE="${2:?--base-image needs a value}"; shift ;;
    --sign) SIGN_IDENTITY="${2:?--sign needs a value}"; SIGN=yes; shift ;;
    --no-sign) SIGN=no ;;
    --notarize) NOTARIZE=yes ;;
    --no-notarize) NOTARIZE=no ;;
    -h | --help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(all)
[[ -n "$SIGN_IDENTITY" && $SIGN == auto ]] && SIGN=yes

WANT_DMG=0 WANT_DEB=0 WANT_APPIMAGE=0
for t in "${TARGETS[@]}"; do
  case "$t" in
    dmg) WANT_DMG=1 ;;
    deb) WANT_DEB=1 ;;
    appimage) WANT_APPIMAGE=1 ;;
    linux) WANT_DEB=1 WANT_APPIMAGE=1 ;;
    all)
      [[ "$(uname -s)" == Darwin ]] && WANT_DMG=1
      WANT_DEB=1 WANT_APPIMAGE=1
      ;;
  esac
done

if [[ -z "$ARCH_ARG" ]]; then
  case "$(uname -m)" in
    x86_64 | amd64) ARCH_ARG=amd64 ;;
    arm64 | aarch64) ARCH_ARG=arm64 ;;
    *) die "unsupported host arch $(uname -m); pass --arch" ;;
  esac
fi
if [[ "$ARCH_ARG" == all ]]; then ARCH_ARG="amd64,arm64"; fi
IFS=',' read -r -a ARCHES <<<"$ARCH_ARG"
for a in "${ARCHES[@]}"; do
  [[ "$a" == amd64 || "$a" == arm64 ]] || die "--arch must be amd64, arm64, a comma list, or all"
done
[[ -z "$JOBS" || "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive number"

case "$(uname -m)" in
  x86_64 | amd64) HOST_ARCH=amd64 ;;
  arm64 | aarch64) HOST_ARCH=arm64 ;;
  *) HOST_ARCH=unknown ;;
esac

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# Version: build.zig.zon version plus the short commit.
ZON_VERSION="$(sed -n 's/^ *\.version = "\(.*\)",/\1/p' "$REPO_ROOT/build.zig.zon" | head -n1)"
GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
VERSION="${ZON_VERSION}+${GIT_SHA}"

# --- macOS signing / notarization -------------------------------------------

# Pick SIGN_IDENTITY before the long build so prompts come first.
choose_sign_identity() {
  [[ $SIGN == no ]] && return 0
  [[ -n "$SIGN_IDENTITY" ]] && return 0

  local ids=()
  while IFS= read -r line; do ids+=("$line"); done < <(
    security find-identity -v -p codesigning |
      sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | sort -u
  )

  if [[ ${#ids[@]} -eq 0 ]]; then
    echo "No 'Developer ID Application' identity found; the dmg will not be signed." >&2
    SIGN=no
  elif [[ ${#ids[@]} -eq 1 ]]; then
    SIGN_IDENTITY="${ids[0]}"
  elif interactive; then
    echo "Pick a signing identity:"
    local i
    for i in "${!ids[@]}"; do echo "  $((i + 1))) ${ids[$i]}"; done
    local n
    read -r -p "Number [1]: " n
    n="${n:-1}"
    [[ "$n" =~ ^[0-9]+$ && $n -ge 1 && $n -le ${#ids[@]} ]] || die "invalid choice"
    SIGN_IDENTITY="${ids[$((n - 1))]}"
  else
    die "several Developer ID identities found; pass --sign IDENTITY"
  fi
  [[ -n "$SIGN_IDENTITY" ]] && SIGN=yes
  return 0
}

# Ask for notarization credentials up front, too.
NOTARY_ARGS=()
choose_notarize() {
  if [[ $SIGN != yes ]]; then
    [[ $NOTARIZE == yes ]] && die "--notarize needs a signing identity"
    NOTARIZE=no
    return 0
  fi
  if [[ $NOTARIZE == auto ]]; then
    if [[ "$SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
      NOTARIZE=no
    elif [[ -n "${NOTARY_PROFILE:-}" || -n "${APPLE_APP_PASSWORD:-}" ]]; then
      NOTARIZE=yes
    elif interactive; then
      local a
      read -r -p "Notarize the dmg with Apple? [Y/n] " a
      [[ "$a" =~ ^[Nn] ]] && NOTARIZE=no || NOTARIZE=yes
    else
      NOTARIZE=no
    fi
  fi
  [[ $NOTARIZE == yes ]] || return 0

  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    return 0
  fi

  local apple_id="${APPLE_ID:-}" team_id="${APPLE_TEAM_ID:-}" password="${APPLE_APP_PASSWORD:-}"
  # The team ID is the bit in parentheses at the end of the identity.
  [[ -z "$team_id" ]] && team_id="$(sed -n 's/.*(\([A-Z0-9]*\))$/\1/p' <<<"$SIGN_IDENTITY")"

  if [[ -z "$apple_id" || -z "$team_id" || -z "$password" ]]; then
    interactive || die "notarization needs APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD (or NOTARY_PROFILE)"
    echo "Notarization credentials (app-specific password from account.apple.com)"
  fi
  [[ -z "$apple_id" ]] && read -r -p "  Apple ID (email): " apple_id
  [[ -z "$team_id" ]] && read -r -p "  Team ID: " team_id
  if [[ -z "$password" ]]; then
    read -r -s -p "  App-specific password: " password
    echo
  fi
  [[ -n "$apple_id" && -n "$team_id" && -n "$password" ]] || die "missing notarization credentials"
  NOTARY_ARGS=(--apple-id "$apple_id" --team-id "$team_id" --password "$password")
}

sign() {
  codesign --force --timestamp --options runtime -s "$SIGN_IDENTITY" "$@"
}

notarize_dmg() {
  local dmg="$1" result status id
  log "Notarizing $(basename "$dmg") (this usually takes a few minutes)"
  result="$(xcrun notarytool submit "$dmg" "${NOTARY_ARGS[@]}" --wait --output-format json)" ||
    die "notarytool submit failed: $result"
  status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || true)"
  id="$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || true)"
  if [[ "$status" != Accepted ]]; then
    echo "Notarization status: ${status:-unknown}" >&2
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" >&2 || true
    die "notarization failed"
  fi
  log "Stapling notarization ticket"
  xcrun stapler staple "$dmg"
}

build_dmg() {
  [[ "$(uname -s)" == Darwin ]] || die "dmg must be built on macOS"
  command -v xcodebuild >/dev/null || die "xcodebuild not found (install Xcode)"

  choose_sign_identity
  choose_notarize

  log "Building Ghostty.app (ReleaseFast)"
  (cd "$REPO_ROOT" && zig build -Doptimize=ReleaseFast)

  local built="$REPO_ROOT/zig-out/Ghostty.app"
  [[ -d "$built" ]] || die "expected $built after build"

  # Work on a copy so re-signing never touches the build output.
  local stage app dmg
  stage="$(mktemp -d)"
  app="$stage/Ghostty.app"
  ditto "$built" "$app"

  if [[ $SIGN == yes ]]; then
    log "Signing app with '$SIGN_IDENTITY'"
    local sparkle="$app/Contents/Frameworks/Sparkle.framework"
    local item
    # Inside-out: nested code first, the app bundle last.
    for item in \
      "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
      "$sparkle/Versions/B/XPCServices/Installer.xpc" \
      "$sparkle/Versions/B/Autoupdate" \
      "$sparkle/Versions/B/Updater.app" \
      "$sparkle" \
      "$app/Contents/PlugIns/DockTilePlugin.plugin"; do
      if [[ -e "$item" ]]; then sign "$item"; fi
    done
    sign --entitlements "$REPO_ROOT/macos/Ghostty.entitlements" "$app"
    codesign --verify --deep --strict "$app"
  fi

  log "Creating dmg"
  ln -s /Applications "$stage/Applications"
  # The app is universal (arm64 + x86_64) by default; name the dmg after
  # what it actually contains.
  local archs label
  archs="$(lipo -archs "$app/Contents/MacOS/ghostty" 2>/dev/null || uname -m)"
  case "$archs" in
    *x86_64*arm64* | *arm64*x86_64*) label=universal ;;
    *) label="$archs" ;;
  esac
  dmg="$OUT_DIR/Ghostty-${VERSION}-macos-${label}.dmg"
  rm -f "$dmg"
  hdiutil create -volname Ghostty -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
  rm -rf "$stage"

  if [[ $SIGN == yes ]]; then
    log "Signing dmg"
    codesign --force --timestamp -s "$SIGN_IDENTITY" "$dmg"
    codesign --verify "$dmg"
  fi

  if [[ $NOTARIZE == yes ]]; then
    notarize_dmg "$dmg"
    spctl --assess --type open --context context:primary-signature -v "$dmg" || true
  fi
  echo "built $dmg (signed: $SIGN, notarized: $NOTARIZE)"
}

# --- Linux (Docker) ---------------------------------------------------------

build_linux() {
  command -v docker >/dev/null || die "docker not found"
  docker info >/dev/null 2>&1 || die "docker daemon is not running"

  local platform="linux/$ARCH"
  local image="ghostty-package-builder:${ARCH}"
  local what=()
  [[ $WANT_DEB == 1 ]] && what+=(deb)
  [[ $WANT_APPIMAGE == 1 ]] && what+=(appimage)

  log "Building Docker image $image from $BASE_IMAGE"
  docker build --platform "$platform" \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    -t "$image" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"

  local maintainer="${DEB_MAINTAINER:-}"
  if [[ -z "$maintainer" ]]; then
    local name email
    name="$(git -C "$REPO_ROOT" config user.name || true)"
    email="$(git -C "$REPO_ROOT" config user.email || true)"
    maintainer="${name:-Ghostty Builder} <${email:-noreply@localhost}>"
  fi

  local jobs="$JOBS"
  if [[ -z "$jobs" && "$ARCH" != "$HOST_ARCH" ]]; then
    jobs=2
    echo "note: $ARCH runs under emulation on this $HOST_ARCH host; using --jobs 2 to avoid running out of memory"
  fi

  # -j only limits build steps; a single step still compiles its C/C++ files
  # on every core it can see. Pinning the container to N CPUs limits both.
  local cpu_args=()
  if [[ -n "$jobs" ]]; then
    local ncpu
    ncpu="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo "$jobs")"
    (( jobs > ncpu )) && jobs="$ncpu"
    cpu_args=(--cpuset-cpus "0-$((jobs - 1))")
  fi

  log "Building ${what[*]} for $ARCH in Docker"
  # The repo is mounted read-only and copied inside the container, so the
  # macOS build in zig-out/.zig-cache is never touched. The Zig package
  # cache lives in a named volume so later runs skip the downloads.
  docker run --rm --platform "$platform" "${cpu_args[@]}" \
    -v "$REPO_ROOT:/src:ro" \
    -v "$OUT_DIR:/out" \
    -v "ghostty-zig-cache-${ARCH}:/root/.cache/zig" \
    -e VERSION="$VERSION" \
    -e DEB_MAINTAINER="$maintainer" \
    -e ZIG_JOBS="$jobs" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    "$image" /src/dist/package/linux-build.sh "${what[@]}"
}

if [[ $WANT_DMG == 1 ]]; then build_dmg; fi
if [[ $WANT_DEB == 1 || $WANT_APPIMAGE == 1 ]]; then
  for ARCH in "${ARCHES[@]}"; do build_linux; done
fi

log "Done. Packages in $OUT_DIR"
ls -lh "$OUT_DIR"
