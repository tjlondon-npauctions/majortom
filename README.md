# Major Tom

*Ground Control to Major Tom: you're running out of space.*

A disk cleaner for developer Macs that tells you what deleting each thing actually costs you before it deletes
anything.

![Major Tom main window](docs/screenshots/main-light.png)

## Install

Needs macOS 15 or later, on Apple Silicon or Intel. No Xcode needed.

```sh
curl -fsSL https://raw.githubusercontent.com/tjlondon-npauctions/majortom/main/install.sh | bash
```

The [installer](install.sh) is short and commented; read it first if you like. It checks your Mac is supported,
downloads the latest release from GitHub, verifies its SHA-256 checksum, installs `MajorTom.app` into
`/Applications` (or `~/Applications` if that isn't writable; never `sudo`), and links the `majortom` command into
`~/.local/bin` or `~/bin` if one of those is on your `PATH`. Run the same command again to update: it asks a
running Major Tom to quit and replaces it. Options go after `bash -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/tjlondon-npauctions/majortom/main/install.sh | bash -s -- --version 1.0.0
curl -fsSL https://raw.githubusercontent.com/tjlondon-npauctions/majortom/main/install.sh | bash -s -- --dir ~/Applications
curl -fsSL https://raw.githubusercontent.com/tjlondon-npauctions/majortom/main/install.sh | bash -s -- --uninstall
```

`--uninstall` removes the app and the command link and keeps your settings and history
(`~/Library/Application Support/MajorTom`).

### Manual download

1. Download `MajorTom-<version>.zip` from [Releases](https://github.com/tjlondon-npauctions/majortom/releases)
   (optionally check it against the `.sha256` file: `shasum -a 256 -c MajorTom-<version>.zip.sha256`).
2. Unzip it and drag `MajorTom.app` to Applications.
3. The first time, macOS refuses to open it because it isn't notarised. Try to open it once (click **Done** on the
   warning), then go to System Settings → Privacy & Security, scroll down and click **Open Anyway**, and confirm.
   (On older macOS this was right-click → **Open**; macOS 15 and later need the System Settings route.)

The command line tool is inside the app: `/Applications/MajorTom.app/Contents/Helpers/majortom`. Link it onto your
`PATH` if you want it, e.g. `ln -s /Applications/MajorTom.app/Contents/Helpers/majortom ~/.local/bin/majortom`.

### Why isn't it notarised?

Notarisation requires a paid Apple Developer account, and this is a free personal project, so releases are only
ad-hoc signed: macOS can check the app hasn't been modified, but not who made it. That's why a downloaded copy is
blocked at first (the manual steps above). The installer uses `curl`, which doesn't mark files as quarantined, and
then removes the quarantine attribute from the installed `MajorTom.app` only, so it opens without the warning; it
changes no Gatekeeper or system setting. One known consequence of ad-hoc signing: each update looks like a new app
to macOS, so it may ask for Full Disk Access (and Documents / Desktop / Downloads access) again after you update.

### Build from source

Needs Xcode 26 (Swift 6.2). See [Build from source](#build-from-source-1) below.

## Why it exists

On a developer Mac, "System Data" quietly grows to fill the disk: Xcode DerivedData, simulator devices and runtimes,
device support files, npm / pnpm / Yarn / Gradle / CocoaPods caches, old Node versions, Android system images, and
`node_modules` folders in projects you haven't opened for months. General-purpose cleaners either miss most of it
or offer a single "Clean" button with no idea what you'll lose.

Major Tom is built around the question you actually ask: *if I delete this, what happens?*

## What makes it different

- **Every item explains itself.** What happens if you delete it, how it comes back, and what it costs (a rebuild, a
  re-download, a re-setup, or nothing).
- **Safety tiers.** *Safe* (regenerates automatically), *Costs time* (works again after a rebuild or download you'll
  notice) and *Review* (your data, or not automatically recoverable).
- **Review before clean.** Every clean is a dry run first, shown in a review sheet listing exactly what will be
  removed and how.
- **Measured results.** Space reclaimed is measured from the disk's free space before and after, not summed from
  estimates.
- **Project hibernation.** Stale projects get their `node_modules`, `Pods`, build output and similar removed, with
  the reinstall command recorded. Source and anything git tracks are never touched.
- **NAS offload with verification.** Move stale projects, Xcode archives and cold large files to a network share;
  the copy is read back and checksummed before the original goes to the Trash. One-click restore.
- **Menu bar alerts.** Free space at a glance, an optional low-space notification, and Quick Clean for safe items.

| | |
|---|---|
| ![Review sheet](docs/screenshots/review-sheet.png) | ![Menu bar](docs/screenshots/menu-bar.png) |
| ![Projects](docs/screenshots/projects.png) | ![Dark mode](docs/screenshots/main-dark.png) |

*Screenshots are taken in fixture mode: the projects and files shown are fake.*

## Features

- Xcode: DerivedData (flags entries whose project is gone), archives, device support, simulator devices, runtimes
  and caches
- JavaScript: npm, pnpm store (`pnpm store prune`), Yarn, Bun, Expo caches, nvm Node versions (active/default
  protected)
- Android: SDK system images, platforms, build-tools, NDK (images no AVD uses are flagged), emulators, Gradle
- Rust (cargo registry, rustup toolchains), Homebrew, CocoaPods, SwiftPM, JetBrains caches (old versions flagged)
- Docker and Time Machine local snapshots (report only, with the commands to run yourself)
- App caches and logs, the Trash
- Large and old files, installer leftovers in Downloads, data left behind by removed apps (all Trash only)
- Projects view with stale detection, git warnings (uncommitted, unpushed, no remote), pin and hide
- NAS offload and restore, history of every real clean
- `majortom` command-line tool with JSON output

Tools you don't have installed simply show nothing.

## Safety model, in plain terms

- Nothing is removed without you reviewing it first. The CLI is a dry run unless you pass `--execute`.
- Right before acting, each path is re-found by its rule and re-checked: it must be inside your home folder (or one
  allow-listed system folder for simulators), never `~`, `~/Library`, `~/Documents`, a project root or a volume
  root, and not reached through a symlink that escapes.
- Caches are deleted outright (trashing a cache frees nothing). Your own files only ever go to the Trash.
- Offloads move the original to the Trash only after the copy on the NAS has been verified.
- It never uses `sudo`. Fixes that need admin rights are shown as a command for you to run.
- Every real clean, hibernation and offload is logged to
  `~/Library/Application Support/MajorTom/history.jsonl`.

## Requirements

- macOS 15 (Sequoia) or later. Developed and tested on macOS 26; on macOS 15 it uses standard controls where
  macOS 26 has Liquid Glass. macOS 15 is supported by the build but hasn't been tested on a real macOS 15 Mac yet.
- Apple Silicon or Intel: releases are universal binaries (arm64 + x86_64). Intel is untested on real hardware.
- To build from source: Xcode 26 / Swift 6.2 (Command Line Tools alone may lack the macOS 26 SDK).

No third-party dependencies.

## First run

- **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access): optional, but without it Major Tom
  can't measure the Trash or check app Containers. macOS also asks once for Documents / Desktop / Downloads access
  on the first scan (used for large and old files). Ad-hoc signed builds may be asked again after each rebuild.
- **Project folders** are detected automatically (`~/Projects`, `~/Developer`, `~/Code`, `~/src`, `~/repos`,
  `~/WebstormProjects`, `~/IdeaProjects`, `~/Documents/GitHub`, …). If none exist, the Projects view offers
  **Add Project Folder…**; change the list any time in Settings → Projects.
- **NAS offload** is off until you choose a folder: connect the share in Finder (⌘K), then **Choose NAS Folder…** in
  the Offload view or Settings → NAS. Local folders are refused.
- **Your own apps:** add your bundle-ID prefix (e.g. `com.yourname.`) under Settings → Files so data from apps you
  build is never called a leftover.

The app has a main window and a menu bar item; closing the window keeps it in the menu bar.

The bundled macOS app supports Simplified Chinese. To choose it for Major Tom, go to
**System Settings → General → Language & Region → Applications**, add Major Tom, choose
**Simplified Chinese**, and reopen the app.

## Command line

```
majortom scan [--rule <id>]... [--items] [--json] [--large-mb N] [--old-days N] [--old-min-mb N]
majortom rules [--json]
majortom clean --rule <id> [--item <id>]... [--flagged] [--action <id>] [--execute] [--json]
majortom history [--json]
majortom projects [--stale] [--dirs] [--json]
majortom offload [--candidates] [--json]
majortom help [<command>]
```

`clean` is a dry run unless `--execute` is given. Without `--item` or `--flagged` it selects every cleanable item of
the rule; each `--item` (id or display name, from `majortom scan --rule <id> --json`) must match exactly one
cleanable item or nothing happens. `--action` can't be combined with `--item`/`--flagged`. `projects` and `offload`
only list; hibernating, offloading and restoring are done in the app.

Valued flags accept `--flag value` or `--flag=value`. Unknown or misspelt flags, a missing value, a repeated
single-value flag or a stray argument is an error (exit 2) before anything is scanned. `--help` / `-h` anywhere
(or `majortom help <command>`) prints help and does nothing else.

## Try it safely: fixture mode

```sh
build/MajorTom.app/Contents/MacOS/MajorTom --fixture
```

Runs the app against a throwaway fake home in the temp folder (deleted on quit), with fake caches, projects and
files, simulated commands, a fixture Trash folder and a fake NAS share. Nothing real is touched, so you can click
every button. `--fixture-empty` shows what a fresh Mac looks like. More dev flags (`--demo`, `--sidebar`,
`--snapshot`) are listed in [CLAUDE.md](CLAUDE.md).

## Adding a rule

Rules live in `Sources/MajorTomCore/Rules/`, one file per category. A rule is a resolver (which paths), a tier, a
removal method, and three honest sentences: impact, recovery and cost. See
[CLAUDE.md → Adding things](CLAUDE.md#adding-things) for the steps and [CONTRIBUTING.md](CONTRIBUTING.md) for the
tests every rule needs.

## Status and limitations

- A personal project, built with AI coding agents (Claude Code) and reviewed by its author. It does what its
  author needs; it is not a product.
- Tested on one Mac. Folder layouts, tool versions and NAS setups on yours may differ.
- Ad-hoc signed and not notarised (see [Why isn't it notarised?](#why-isnt-it-notarised)).
- Not sandboxed (it couldn't do its job otherwise) and not on the App Store.
- Real notifications and the login item have only been exercised through test fakes.
- See [SPEC.md](SPEC.md) for the full behaviour and [PROGRESS.md](PROGRESS.md) for what each milestone built and
  what is still open.

## Build from source

```sh
git clone https://github.com/tjlondon-npauctions/majortom.git MajorTom && cd MajorTom
swift build && swift test     # debug build + fixture-based tests (temp folders only)
scripts/bundle.sh             # release build -> build/MajorTom.app (universal, ad-hoc signed)
open build/MajorTom.app
```

`build/majortom` links to the CLI inside the bundle. To copy your build into `/Applications` (or `~/Applications`):

```sh
scripts/install-from-source.sh --dry-run  # show what it would do
scripts/install-from-source.sh
```

It never uses `sudo`, refuses to overwrite anything that isn't a Major Tom build, and refuses while that copy is
running. `OUT_DIR=<folder>` builds somewhere other than `build/`; `ARCHS=arm64` builds one architecture only
(faster); `BUNDLE_ID=<id>` changes the bundle identifier. The version comes from the `VERSION` file.

## Disclaimer

Major Tom deletes files. It tries hard to delete only what you confirm, but it comes with **no warranty of any
kind**. Read the review sheet before every clean, keep backups, and don't clean anything you don't understand.

## Licence

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 Tom Jordan.
