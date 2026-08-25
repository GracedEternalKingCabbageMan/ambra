# Ambra

Non-custodial dual-chain mobile wallet for Bitcoin (testnet4) and Sequentia: a Flutter UI
over a shared Rust core. Android-first; `app/ios/` is a scaffold only.

Everything here is testnet. Node and consensus conventions live in the
[`Sequentia`](https://github.com/ConcatenaLabs/Sequentia) repo, not here.

## Layout

| Path | What it is |
|---|---|
| `ambra_core/` | The Rust crate (`ambra_core`), `crate-type = ["cdylib", "staticlib", "lib"]`. FFI surface is `ambra_core/src/api/mod.rs` and `src/api/signer.rs`. |
| `app/` | The Flutter app. **`pubspec.yaml` lives at `app/pubspec.yaml`, not at the repo root.** |
| `app/lib/src/rust/` | Generated flutter_rust_bridge bindings. Committed, but never hand-edited. |
| `docs/SPEC.md` | Product and design spec, including the finality-UX rules. |

## It does not build standalone

`ambra_core/Cargo.toml` takes a `path` dependency on `../../seqln/contrib/seqln-signer` and
carries a `[patch.crates-io]` block redirecting `lwk_common`, `lwk_signer`, `lwk_wollet` and
`elements` to `../../SWK/`. **SWK and seqln must be checked out as siblings of `ambra/`**, on
the branches the README names:

```sh
git clone https://github.com/ConcatenaLabs/ambra.git
git clone -b sequentia https://github.com/ConcatenaLabs/SWK.git
git clone -b sequentia-stable https://github.com/ConcatenaLabs/seqln.git
```

## Build and test

Toolchain per the README: Linux host, Rust stable, Flutter with Dart SDK >= 3.12, Android SDK
with NDK `29.0.14206865` (pinned in `app/android/app/build.gradle.kts`), `cargo-ndk`, and
`flutter_rust_bridge_codegen` 2.12.0.

```sh
# Rust core (host build; also produces the cdylib the Flutter host tests load)
cd ambra_core && cargo build

# Cross-compile for Android
rustup target add aarch64-linux-android
cargo install cargo-ndk
cargo ndk -t arm64-v8a -o ../app/android/app/src/main/jniLibs build --release

# App
cd ../app && flutter pub get
flutter build apk --release        # or: flutter run
```

Tests, from `ambra_core/`:

```sh
cargo test --test smoke --test signer_conformance
cargo test --test sync -- --nocapture
```

A bare `cargo test` runs the network tests too, so prefer the explicit forms offline.

From `app/`:

```sh
flutter test test/lsp_client_test.dart   # pure-Dart, mocked HTTP, runs anywhere
flutter test                             # host tests load the cdylib
```

The host tests resolve the core library from `$AMBRA_CORE_LIB`, defaulting to
`../ambra_core/target/debug/libambra_core.so` (`app/test/widget_test.dart`), so build the host
crate first or set that variable.

`flutter analyze` is the standing gate; commit bodies record it.

There is no CI in this repository. Nothing checks a build or a test for you.

## Three things that get forgotten

1. **Touching `ambra_core` means rebuilding the Android `.so`.**
   `app/android/app/src/main/jniLibs/` is gitignored and never committed, so a stale `.so`
   survives a `git pull` and the app silently runs old Rust. The tree carries three ABIs
   (`arm64-v8a`, `armeabi-v7a`, `x86_64`); the README documents only the `arm64-v8a` command.
   History records this going wrong ("x86_64 was stale"), which is why commit bodies state
   whether Rust was touched.
2. **Changing `ambra_core::api` means regenerating the bridge.** Run
   `flutter_rust_bridge_codegen generate` from `app/` (config: `app/flutter_rust_bridge.yaml`).
   The `flutter_rust_bridge` version is pinned to exactly 2.12.0 on both sides and the codegen
   binary must match.
3. **Never claim a change works until it has been exercised on-device.** Analyzer-clean plus
   green Dart tests does not cover the FFI boundary or the native libs. Several commits exist
   solely to fix things that passed everything except a real device.

## Version

`app/pubspec.yaml` carries the version (`0.x` = pre-mainnet, minor tracks the milestone, bump
the build number every release, `1.0.0` at mainnet). Release commits are titled
`ambra 0.X.Y: <summary>` and touch `app/pubspec.yaml` alone.

`kAppVersion` in `app/lib/src/data/config.dart` is a *separate* constant, and it is what the UI
footer renders (`app/lib/src/screens/shell.dart`). Bump both in the same commit. It matches
pubspec now; it has drifted twice before (fixed in `1e839c9` and again at 0.16.4).

## Release signing

`app/android/app/build.gradle.kts` loads `key.properties` from the Android root project and
uses it for the `release` signing config. If that file is absent it falls back to the **debug**
signing config without failing the build, so an unsigned-for-distribution APK looks like a
successful release build. Release APKs signed with a machine-local debug key install as
"package appears to be invalid" (fixed in `a85a9e9`); switching an already-installed app from
debug to release signing requires one uninstall, after which updates apply cleanly.

`key.properties`, `**/*.keystore` and `**/*.jks` are gitignored. Keep it that way.

## Working in this repo

- **Repository is public.** Never commit seeds, private keys, keystores, credentials, RPC
  auth, `.env` files or tokens. Test fixtures use only the well-known all-zero BIP39 vector.
- **Commit author:**
  `GracedEternalKingCabbageMan <151803062+GracedEternalKingCabbageMan@users.noreply.github.com>`
- **Always open a pull request, then merge it yourself immediately.** The PR exists so the
  change and its reasoning are recorded, not because anyone is waiting to review it. There is
  no review process. If you are ever told to leave one specific PR open, that applies to that
  PR only and never becomes the default.
- The remote default branch is `main` and all development lands there. `terminal-rebuild`
  is fully merged into `main` and is no longer a base for anything.

## README drift

The top-level `README.md` documents only the `arm64-v8a` cross-compile, while the tree
carries three ABIs (see above). Verify against the code before repeating anything from it.

<!-- BEGIN SHARED AGENT CONVENTIONS: identical in every Sequentia repo. Change it in all of them together. -->
## Working with git and GitHub here

These rules are the same in every Sequentia repository. They are repeated in each
one because this file is the only thing an agent is guaranteed to read, whatever
machine it is working from.

**Nothing pushed to GitHub credits Claude, Anthropic, or any AI tool.** No
`Co-Authored-By: Claude` trailer, no `Claude-Session:` trailer or `claude.ai`
link, no "Generated with Claude Code" in a commit message or a pull request body,
no `claude/*` branch names or session ids, and no mention in source, comments,
docs or issue text. Agent tooling offers several of these by default; compose the
message without them rather than stripping them afterwards.

**Author every commit as**
`GracedEternalKingCabbageMan <151803062+GracedEternalKingCabbageMan@users.noreply.github.com>`.
Never a personal address.

**Every change lands through a pull request that you merge yourself, at once.**
There is no reviewer on this project; the pull request exists so the reasoning is
recorded beside the diff. Branch, push, open it, merge it, delete the branch, all
in one sitting. Pushing straight to the default branch is the rule most often
broken here, and it is the one that costs the record. A pull request stays open
only when the repository owner asks for that specific one, and that never carries
over to the next.

**Name branches `area/short-description`**: `fix/`, `doc/`, `feature/`, `test/`,
`build/`, or the component being changed. Never a tool name, a session id, or
`worktree-*`.

**Write the subject as `area: what changed`**, one line, 72 characters at the
outside and 50 where you can manage it. Put the reasoning in the body, and
explain why rather than what.

**These repositories are public and world-readable.** Never commit private keys,
seeds, `wallet.dat`, RPC credentials, `.env` files or API tokens. Read the diff
before every commit. Secrets belong on the server and in offline backups.

**A file belongs to the repository whose code it describes.** Decide which repo
owns it before writing it; if it landed in the wrong one, move it rather than
deleting it.

**Documentation is part of the change, not a follow-up.** A change that makes a
README, a doc page, a runbook or a code comment wrong is not finished until that
text is right again, in the same pull request as the code. Before you open the
pull request, search the repository for whatever you renamed, moved or removed —
the old binary name, the old path, the old flag, the old command — and fix every
hit. If the change falsifies another repository's documentation, that repository
gets its own pull request in the same sitting. A stale instruction costs a new
user more than a missing one: they trust it, run it, it fails, and the failure
reads as broken software rather than as an out-of-date sentence.

**Write documentation to be timeless.** Assume the reader is new, arrived today,
and wants to know what the software is and how to use it right now. They do not
care what changed, what it used to be called, or which version added what. So
write in the present tense about current behaviour, and leave the history out:
no changelogs, no "new in", no "recently", no "coming soon", no status or
progress sections, no roadmaps, no dated notes. Quote a version number only where
the reader cannot act without it, and prefer pointing at the file that carries it
over copying the digits. Timeless does not mean thin — what the product is, who
it is for, and how to install, configure and use it all still belong there, in
full. Documentation written this way survives a release without an edit, which is
what keeps it true; the history already has homes in the git log, the tags and
the release notes.

**Push the same day you commit.** The testnet server pulls only from GitHub, so a
branch left on one laptop is invisible to every other machine and to the box.
<!-- END SHARED AGENT CONVENTIONS -->
