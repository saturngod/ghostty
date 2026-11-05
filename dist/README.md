# Packaging

Release packages are built with one script, `dist/package/build.sh`.

| Package | Format | Built on |
| --- | --- | --- |
| macOS app | `.dmg` (signed, optionally notarized) | macOS with Xcode |
| Debian / Ubuntu | `.deb` | Linux, or macOS via Docker |
| Linux | `.AppImage` | Linux, or macOS via Docker |

Output goes to `zig-out/packages/`.

## Requirements

- **dmg:** macOS, Xcode, and Zig.
- **deb / AppImage:** Docker running. The build happens inside an Ubuntu 26.04 container, so it works from macOS too.

## Commands

Build the dmg (macOS):

```bash
dist/package/build.sh dmg
```

Build the Linux packages:

```bash
dist/package/build.sh deb appimage
```

Or just `dist/package/build.sh linux`, which does the same thing.

Build everything (on macOS this makes the dmg and the Linux packages):

```bash
dist/package/build.sh all
```

Show all options:

```bash
dist/package/build.sh --help
```

## Options

| Option | Meaning |
| --- | --- |
| `--arch LIST` | Linux target architectures: `amd64`, `arm64`, a comma list (`amd64,arm64`), or `all`. Defaults to the host's. A foreign architecture runs under emulation and is slow. |
| `--jobs N` | Parallel compile jobs for the Linux build. Defaults to all cores natively and 2 under emulation, where compiles use a lot of memory and get killed. |
| `--out DIR` | Output directory. Defaults to `zig-out/packages`. |
| `--base-image IMAGE` | Docker base image for the Linux build. Defaults to `ubuntu:26.04`. |
| `--sign IDENTITY` | Code-signing identity for the app and dmg. |
| `--no-sign` | Skip signing. Gatekeeper will block the app on other Macs. |
| `--notarize` / `--no-notarize` | Force notarization on or off. |

## Signing and notarization (dmg)

By default the script looks for a `Developer ID Application` certificate in your keychain. If it finds one, it signs the app and the dmg. If there are several, it asks you to pick one.

After signing, it asks whether to notarize with Apple. If you say yes, it needs:

- your Apple ID email,
- your Team ID (read from the certificate automatically),
- an app-specific password from [account.apple.com](https://account.apple.com) under Sign-In and Security.

The password is typed hidden and is never written to disk.

To skip the prompts, set environment variables instead:

```bash
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="4UP69BH7R6"
export APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
```

Or save credentials once and reuse them:

```bash
xcrun notarytool store-credentials "notarytool-profile" \
  --apple-id "you@example.com" --team-id "4UP69BH7R6"
export NOTARY_PROFILE="notarytool-profile"
```

Notarization can take several minutes. On failure the script prints Apple's log.

Developer ID certificates are needed for distribution. `Apple Development` certificates sign builds for your own machine only.

## Environment variables

| Variable | Meaning |
| --- | --- |
| `MACOS_SIGN_IDENTITY` | Same as `--sign`. |
| `NOTARY_PROFILE` | A profile saved with `xcrun notarytool store-credentials`. |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | Notarization credentials. |
| `DEB_MAINTAINER` | The `Maintainer:` field of the `.deb`. Defaults to your git name and email. |

## How the Linux packages are built

1. `dist/package/Dockerfile` builds an Ubuntu 26.04 image with Zig, GTK 4, libadwaita, a newer `blueprint-compiler` (the distro one is too old), and linuxdeploy.
2. `dist/package/linux-build.sh` runs inside the container. It copies the tracked and untracked (non-ignored) files, builds Ghostty once with `ReleaseFast`, and packages the result as a `.deb` and/or an AppImage.

The repository is mounted read-only, so the macOS build outputs are not touched. The Zig package cache is kept in a Docker volume, so later builds are faster.

## GitHub Actions

Push to `main` and `.github/workflows/package.yml` builds the Linux
packages and puts them on the `tip` release (Releases page). Each push
replaces the files, so the download links never change:

- `ghostty_amd64.deb`, `Ghostty-amd64.AppImage` (Intel/AMD PCs)
- `ghostty_arm64.deb`, `Ghostty-arm64.AppImage` (ARM)

For example:
`https://github.com/<owner>/<repo>/releases/download/tip/ghostty_amd64.deb`

The macOS dmg is not built in CI. Build and sign it on your Mac with
`dist/package/build.sh dmg`. The app is universal (Apple Silicon and Intel),
so one dmg covers both.

## Compatibility

- The Linux packages need a distro at least as new as Ubuntu 26.04 (glibc 2.43, GTK 4.21, libadwaita 1.7).
- `ghostty --version` in the Linux builds shows `+0000000` instead of the commit, because the git history is not copied into the container.

## Troubleshooting

- **Disk full:** the build needs several GB free on the volume holding the repo and `.zig-cache`.
- **`blueprint-compiler is the wrong version`:** rebuild the Docker image so it picks up the source build of `blueprint-compiler` (`docker rmi ghostty-package-builder:arm64`, then rerun).
- **`docker daemon is not running`:** start Docker Desktop.
