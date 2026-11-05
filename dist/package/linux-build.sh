#!/usr/bin/env bash
# Runs inside the Docker image from dist/package/Dockerfile.
# Builds Ghostty once and packages it as a .deb and/or AppImage into /out.
#
#   linux-build.sh deb appimage
set -euo pipefail

WANT_DEB=0 WANT_APPIMAGE=0
for t in "$@"; do
  case "$t" in
    deb) WANT_DEB=1 ;;
    appimage) WANT_APPIMAGE=1 ;;
    *) echo "unknown target $t" >&2; exit 1 ;;
  esac
done

VERSION="${VERSION:-0.0.0}"
DEB_ARCH="$(dpkg --print-architecture)"
UNAME_ARCH="$(uname -m)"
SRC=/work/src
STAGE=/work/stage
OUT=/out

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# Hand finished files back to the host user, not root.
fix_owner() { [[ -n "${HOST_UID:-}" ]] && chown "$HOST_UID:${HOST_GID:-$HOST_UID}" "$@" || true; }

log "Copying source"
git config --global --add safe.directory /src
rm -rf "$SRC" "$STAGE"
mkdir -p "$SRC"
# Tracked + untracked-but-not-ignored files, so local edits are included and
# the host's build outputs are not.
(cd /src && git ls-files -z -co --exclude-standard |
  tar --null --ignore-failed-read -T - -cf -) | tar -C "$SRC" -xf -

log "Building Ghostty (ReleaseFast, $UNAME_ARCH)"
cd "$SRC"
# We link -lbzip2 but Ubuntu only ships libbz2.so (same workaround as the snap).
mkdir -p /work/bzip2-redirect/lib
echo 'INPUT(libbz2.so)' > /work/bzip2-redirect/lib/libbzip2.so

jobs_arg=()
if [[ -n "${ZIG_JOBS:-}" ]]; then jobs_arg=("-j${ZIG_JOBS}"); fi

DESTDIR="$STAGE" zig build "${jobs_arg[@]}" \
  --prefix /usr \
  --search-prefix /work/bzip2-redirect \
  -Doptimize=ReleaseFast \
  -Dcpu=baseline \
  -fsys=gtk4-layer-shell \
  -fsys=freetype \
  -fsys=fontconfig \
  -fsys=harfbuzz \
  -fsys=libpng \
  -fsys=zlib

[[ -x "$STAGE/usr/bin/ghostty" ]] || { echo "build produced no ghostty binary" >&2; exit 1; }

build_deb() {
  log "Packaging .deb"
  # Debian versions can't contain '-' without a revision; use '~' so a
  # "-dev" build sorts before the matching release.
  local deb_version="${VERSION//-/\~}-1"
  local root=/work/deb
  rm -rf "$root"
  mkdir -p "$root/DEBIAN"
  cp -a "$STAGE/usr" "$root/usr"

  local extra_depends=""
  # Newer ncurses-term ships xterm-ghostty itself; installing ours too would
  # be a file conflict, so defer to it when it has one.
  if dpkg -L ncurses-term 2>/dev/null | grep -q '/xterm-ghostty$'; then
    rm -rf "$root/usr/share/terminfo"
    extra_depends=", ncurses-term"
  fi

  # Work out library dependencies from the binary.
  local shl=/work/shlibdeps
  rm -rf "$shl"
  mkdir -p "$shl/debian"
  printf 'Source: ghostty\n\nPackage: ghostty\nArchitecture: any\n' > "$shl/debian/control"
  local depends
  depends="$(cd "$shl" && dpkg-shlibdeps -O "$root/usr/bin/ghostty" 2>/dev/null |
    sed -n 's/^shlibs:Depends=//p')"

  local size
  size="$(du -sk "$root/usr" | cut -f1)"

  cat > "$root/DEBIAN/control" <<EOF
Package: ghostty
Version: ${deb_version}
Architecture: ${DEB_ARCH}
Maintainer: ${DEB_MAINTAINER:-Ghostty Builder <noreply@localhost>}
Installed-Size: ${size}
Depends: ${depends}${extra_depends}
Section: x11
Priority: optional
Homepage: https://ghostty.org
Description: Fast, native, feature-rich terminal emulator
 Ghostty is a terminal emulator that differentiates itself by being
 fast, feature-rich, and native. It uses GPU acceleration and a
 platform-native UI.
EOF

  find "$root" -type d -exec chmod 0755 {} +
  local deb="$OUT/ghostty_${deb_version}_${DEB_ARCH}.deb"
  dpkg-deb --root-owner-group --build "$root" "$deb" >/dev/null
  fix_owner "$deb"
  echo "built $deb"
}

build_appimage() {
  log "Packaging AppImage"
  local appdir=/work/AppDir
  rm -rf "$appdir"
  mkdir -p "$appdir"
  cp -a "$STAGE/usr" "$appdir/usr"

  local desktop="$appdir/usr/share/applications/com.mitchellh.ghostty.desktop"
  local icon="" size
  for size in 512x512 256x256 128x128; do
    if [[ -f "$appdir/usr/share/icons/hicolor/$size/apps/com.mitchellh.ghostty.png" ]]; then
      icon="$appdir/usr/share/icons/hicolor/$size/apps/com.mitchellh.ghostty.png"
      break
    fi
  done
  [[ -n "$icon" ]] || icon="$(find "$appdir/usr/share/icons" -name 'com.mitchellh.ghostty.png' | head -n1)"

  export DEPLOY_GTK_VERSION=4
  linuxdeploy --appdir "$appdir" \
    --executable "$appdir/usr/bin/ghostty" \
    --desktop-file "$desktop" \
    --icon-file "$icon" \
    --plugin gtk

  # The GTK plugin forces GDK_BACKEND=x11; Ghostty works fine on Wayland.
  local hook
  for hook in "$appdir"/apprun-hooks/*gtk*.sh; do
    [[ -f "$hook" ]] && sed -i '/GDK_BACKEND/d' "$hook"
  done

  local out="$OUT/Ghostty-${VERSION}-${UNAME_ARCH}.AppImage"
  (cd /work && LDAI_OUTPUT="$out" OUTPUT="$out" \
    linuxdeploy --appdir "$appdir" --output appimage)
  fix_owner "$out"
  echo "built $out"
}

[[ $WANT_DEB == 1 ]] && build_deb
[[ $WANT_APPIMAGE == 1 ]] && build_appimage
exit 0
