# Build environment for Ghostty's Linux packages (.deb and AppImage).
# Used by dist/package/build.sh.
ARG BASE_IMAGE=ubuntu:26.04
FROM ${BASE_IMAGE}

# Keep in sync with minimum_zig_version in build.zig.zon.
ARG ZIG_VERSION=0.17.0
# Keep in sync with required_blueprint_version in
# src/apprt/gtk/build/blueprint.zig (distro packages are often older).
ARG BLUEPRINT_VERSION=0.20.0

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils git file patchelf dpkg-dev pkg-config \
      libgtk-4-dev libgtk4-layer-shell-dev libadwaita-1-dev \
      meson ninja-build python3 python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 \
      libxml2-utils gettext \
      libbz2-dev libfontconfig-dev libfreetype-dev libharfbuzz-dev \
      libpng-dev zlib1g-dev \
      libglib2.0-bin librsvg2-common shared-mime-info desktop-file-utils \
      ncurses-term \
    && rm -rf /var/lib/apt/lists/* \
    # linuxdeploy-plugin-gtk copies $libdir/gtk-4.0, which newer GTK builds
    # no longer ship (no loadable modules). Give it an empty one.
    && mkdir -p "$(pkg-config --variable=libdir gtk4)/gtk-4.0"

# blueprint-compiler from upstream
RUN set -eux; \
    git clone --depth 1 --branch "v${BLUEPRINT_VERSION}" \
      https://gitlab.gnome.org/GNOME/blueprint-compiler.git /tmp/blueprint; \
    cd /tmp/blueprint; \
    meson setup build --prefix=/usr/local; \
    meson install -C build; \
    cd /; rm -rf /tmp/blueprint; \
    blueprint-compiler --version

# Zig
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64) arch=x86_64 ;; aarch64) arch=aarch64 ;; \
      *) echo "unsupported arch $(uname -m)"; exit 1 ;; \
    esac; \
    curl -fL --retry 5 -o /tmp/zig.tar.xz \
      "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz"; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    zig version

# linuxdeploy + GTK and AppImage plugins. The AppImages are unpacked so they
# run without FUSE inside the container.
RUN set -eux; \
    arch="$(uname -m)"; \
    base=https://github.com/linuxdeploy; \
    cd /opt; \
    curl -fL --retry 5 -o ld.AppImage \
      "$base/linuxdeploy/releases/download/continuous/linuxdeploy-${arch}.AppImage"; \
    curl -fL --retry 5 -o ldai.AppImage \
      "$base/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-${arch}.AppImage"; \
    chmod +x ld.AppImage ldai.AppImage; \
    ./ld.AppImage --appimage-extract >/dev/null && mv squashfs-root linuxdeploy; \
    ./ldai.AppImage --appimage-extract >/dev/null && mv squashfs-root linuxdeploy-plugin-appimage; \
    rm ld.AppImage ldai.AppImage; \
    printf '#!/bin/sh\nexec /opt/linuxdeploy/AppRun "$@"\n' > /usr/local/bin/linuxdeploy; \
    printf '#!/bin/sh\nexec /opt/linuxdeploy-plugin-appimage/AppRun "$@"\n' > /usr/local/bin/linuxdeploy-plugin-appimage; \
    curl -fL --retry 5 -o /usr/local/bin/linuxdeploy-plugin-gtk \
      "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh"; \
    chmod +x /usr/local/bin/linuxdeploy /usr/local/bin/linuxdeploy-plugin-appimage /usr/local/bin/linuxdeploy-plugin-gtk

# Never let an AppImage tool try to mount itself.
ENV APPIMAGE_EXTRACT_AND_RUN=1
WORKDIR /work
