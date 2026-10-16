# AGENTS.md

Handoff notes for this repo so a fresh session can build, commit and release without rediscovering the setup.

## What this repo is

- A **fork** of the Flutter Android app Aves. `origin` = `https://github.com/beomyo/aves.git`, default/working branch = **`develop`**. Upstream is `deckerst/aves`.
- Package id `deckers.thibault.aves`. This fork adds WebDAV/SMB ("cloud") browsing and a custom remote video player.
- There is a real `.git` directory (do not assume otherwise). Working tree should normally be clean.
- Build output APKs land in `build/app/outputs/flutter-apk/`.

## Toolchain (installed outside the repo — do not reinstall)

| | Path |
|---|---|
| Flutter 3.47.6 | `/opt/flutter` |
| Android SDK | `/opt/android-sdk` (platform android-37, build-tools 37.0.0) |
| JDK 21 | `/usr/lib/jvm/java-21-openjdk-amd64` |

- Use `/opt/flutter/bin/flutter` **directly**. Do **not** use `./flutterw`: it resolves Flutter from the `.flutter` git submodule, which is checked out empty here.
- `android/local.properties` points at `/opt/android-sdk` + `/opt/flutter` (machine-specific, gitignored).
- `android/key.properties` exists locally (gitignored) and points at `/opt/aves-release.keystore` (store/key pass `avesdebug`, alias `aves`). Release builds are therefore **signed as-is** (v2+v3; v1 is intentionally absent because minSdk=24).

## Network / proxy (required)

All outbound network needs an HTTP proxy: **`http://10.2.31.10:7899`** (github.com, pub.dev, dl.google.com, maven).

```bash
export https_proxy=http://10.2.31.10:7899 http_proxy=http://10.2.31.10:7899
export PATH=/opt/flutter/bin:$PATH
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
export ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk
```

Already configured globally for git (`http.proxy`) and Gradle (`~/.gradle/gradle.properties`), so a bare `git push` / Gradle fetch works once the env above is exported.

**libmpv JAR pitfall:** the Gradle plugin `media_kit_libs_android_video` downloads 4 libmpv JARs from GitHub releases via Java `URL.openStream()`, which the proxy resets. If the build fails there, pre-download them into `build/media_kit_libs_android_video/v1.1.7/` (md5s are listed in the plugin's `android/build.gradle`).
**`flutter clean` deletes that directory** — back the JARs up before cleaning and restore them after:
```bash
cp build/media_kit_libs_android_video/v1.1.7/*.jar /tmp/mk_jars/
flutter clean
mkdir -p build/media_kit_libs_android_video/v1.1.7 && cp /tmp/mk_jars/*.jar build/media_kit_libs_android_video/v1.1.7/
```

## Build

Build **from the ROOT `pubspec.yaml`**. Do **not** run `scripts/apply_flavor_*.sh` first: `flavors/pubspec_*.yaml` (and their `.lock` files) are stale — they lack `smb_connect`, so applying them breaks the build. Root `pubspec.lock` is the good one and is what actually gets used.

```bash
# release, per-ABI (the shipping build)
flutter build apk --release --flavor play -t lib/main_play.dart --split-per-abi
# -> build/app/outputs/flutter-apk/app-<abi>-play-release.apk  (abi = arm64-v8a, armeabi-v7a, x86_64)

# quick smoke build while iterating (no R8, faster)
flutter build apk --debug --flavor play -t lib/main_play.dart
```

- `android/app/build.gradle.kts`: `isMinifyEnabled=true`, `isShrinkResources=true`, R8 full mode, `useLegacyPackaging=true` (compressed native libs), ABI filter {armeabi-v7a, arm64-v8a, x86_64}, versionCode = base*100 + abiCode.
- Per-ABI release APKs are ~26 MB. Adding a large native dependency is expensive (libvlc added ~20 MB/ABI) — validate the size delta when adding native deps.
- l10n is generated into `lib/l10ngen/` (gitignored). `flutter pub get` regenerates it. "untranslated message" warnings during pub get are normal.
- Localization source files: `lib/l10n/app_*.arb` (en is the template). Add new strings to `app_en.arb` + `app_zh.arb` + `app_zh_Hant.arb` at minimum.

### Verify an APK before handing it over

```bash
BT=/opt/android-sdk/build-tools/37.0.0
"$BT/apksigner" verify --verbose app-arm64-v8a-play-release.apk   # expect v2+v3, v1 false is OK (minSdk 24)
"$BT/aapt" dump badging app-arm64-v8a-play-release.apk | grep -E '^package:|native-code'
```
Never give the user an APK from `build/app/outputs/` without running `apksigner verify` on it.

## Checks

```bash
flutter pub get            # also regenerates l10n
flutter analyze            # expected clean except one pre-existing unrelated test warning
dart analyze <changed paths>   # faster while iterating
```

## Commit & push

Commit style: a short subject + a bullet body explaining *why*, matching the existing history.

```bash
git add -A
git -c user.name="$(git config user.name || echo beomyo)" commit -F - <<'MSG'
Short subject line

- bullet explaining the change and its rationale
- bump version to X.Y.Z+N
MSG
```

Push needs a GitHub token (the release PAT). **Never write the token into the repo, `AGENTS.md`, or `.git/config`.** Use a throwaway 0600 file and a `credential.helper`, then delete it:

```bash
umask 077 && printf '%s' "$GH_TOKEN" > /tmp/.ghtok && chmod 600 /tmp/.ghtok
export https_proxy=http://10.2.31.10:7899 http_proxy=http://10.2.31.10:7899
git -c http.proxy=http://10.2.31.10:7899 -c https.proxy=http://10.2.31.10:7899 \
    -c credential.helper='!f() { echo username=x-access-token; echo "password=$(cat /tmp/.ghtok)"; }; f' \
    push origin develop 2>&1 | sed -E 's/ghp_[A-Za-z0-9]+/ghp_***/g'
rm -f /tmp/.ghtok
```
Always pipe push output through the `sed` redaction above. `gh` is not installed — use the REST API.

**Security:** the user's PAT has historically had near-full scopes (`admin:org`, `delete_repo`, `workflow`, `repo`) and has been pasted in chat. Do not echo it, do not persist it, and remind the user to rotate it to a `contents:write`-only fine-grained token.

## Version bump

Bump `version:` in **all four** files together (they must stay in sync): `pubspec.yaml`, `flavors/pubspec_play.yaml`, `flavors/pubspec_izzy.yaml`, `flavors/pubspec_libre.yaml`. Also add a `CHANGELOG.md` entry.

## Release ("发布" / publish)

"发布" means: build locally → commit + push `develop` → create a **GitHub Release** via the REST API with the APKs as assets. GitHub Actions cannot do it (the fork lacks the required repo secrets).

Convention:
- tag `v<version>-cloud`, created at the pushed commit (`target_commitish` = HEAD SHA)
- release name `Aves <version> + WebDAV & SMB browsing` (or a short feature description)
- assets renamed `aves-<version>-cloud-<abi>.apk` for abi in {arm64-v8a, armeabi-v7a, x86_64}
- body: "Fixed/Added in this version" + Notes (test key / Android 7.0+ / AList `/dav` hint) + Assets list

Steps (Python + `urllib` with the proxy; `gh` is unavailable):
1. `git rev-parse HEAD` → SHA.
2. `POST https://api.github.com/repos/beomyo/aves/releases` with `Authorization: Bearer <token>`, `tag_name`, `target_commitish`, `name`, `body`, `draft:false`.
3. For each APK: `POST https://uploads.github.com/repos/beomyo/aves/releases/<id>/assets?name=<file>` with `Content-Type: application/octet-stream` and the raw bytes (timeout 600s; uploads are ~26 MB each).
4. Verify with `GET .../releases/tags/<tag>` and print the asset names/sizes.
5. Remove the token temp file.

## Known upstream gotchas

- **`media_kit_video` re-seeks on surface attach.** Its Android controller (`android_video_controller/real.dart`, `widListener`) calls `player.seek(player.state.position)` whenever the video surface id changes. The surface attaches right after the player reports ready — i.e. right after any programmatic resume seek — and re-seeks to a still-stale position, restarting playback from the start. Resuming therefore needs to hold/re-assert the position across that window.
- **Adding a native Flutter plugin under AGP 9 is not drop-in.** A plugin whose Android module uses the legacy pattern (`buildscript { classpath 'com.android.tools.build:gradle:8.x' }` + `apply plugin: "kotlin-android"` + `kotlinOptions {}`) fails to configure under AGP 9.4.1. Vendor it under `plugins/` and patch the Gradle file (drop the buildscript/kotlin plugin/kotlinOptions, hoist `dependencies {}`, bump `compileSdk`), then exclude it from analysis in `analysis_options.yaml`.
- This repo uses Dart 3.13 syntax: **primary constructors** (`class Foo(this.bar, {required super.x})`) and shorthand enums/switch (`.idle`, `.never`). Match the surrounding style.

## Environment assumptions to re-verify

If something below doesn't match, trust the current tree over this file:
- `git branch --show-current` → `develop`
- `grep '^version' pubspec.yaml` → current version
- `android/key.properties` and `/opt/aves-release.keystore` still exist
- `~/.gradle/gradle.properties` still has the proxy
