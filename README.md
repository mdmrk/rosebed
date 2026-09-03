# Rosebed

[![license](https://img.shields.io/github/license/mdmrk/rosebed)](LICENSE)

A from-scratch reimplementation of Minecraft Beta 1.7.3 in Zig, using SDL3 and OpenGL 3.3. Client and dedicated server, both speaking the b1.7.3 protocol (version 14).

> [!NOTE]
> **The goal** is a standalone b1.7.3 you can actually play: same behavior, same world out of the same seed, same packets on the wire. One native binary, and nothing beyond b1.7.3.

> [!IMPORTANT]
> **Work in progress.** Most of the game is playable, so what's left is the fine detail. Anything that behaves differently than it does in the real b1.7.3 counts as a bug: terrain, block or mob behavior, a sound, etc. If you spot one, [please open an issue](https://github.com/mdmrk/rosebed/issues) with what you did and what the original does instead.

## Index

- [Not in b1.7.3](#not-in-b173)
- [Play](#play)
- [Build](#build)
  - [Web](#web)
  - [Android](#android)
- [License](#license)

## Not in b1.7.3

The short list of things b1.7.3 does not have. Everything else is meant to match it, and anything that doesn't is a bug.

- [x] **Chat and commands in single player** - `/help`, `/freecam`, `/give`, `/kill`, `/spawn`, ...
- [x] **Chat input editing** - History recall, ctrl+backspace, paste.
- [x] **Fullscreen in Video Settings** - Vanilla has F11 and no setting.
- [x] **On-screen touch controls** - Only on Android, where there is no keyboard or mouse to bind.
- [x] **Auto-jump** - Android only, on by default, toggled in Options.

## Play

**[Play browser build online](https://mdmrk.github.io/rosebed/)**. Worlds are saved in browser storage. Needs WebGL2.

| Platform            | Stable                                                                                               | Nightly                                                                                                                                                                                                                                                                                            |
| ------------------- | ---------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `x86_64-linux`      | [tar.gz](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-linux-x86_64.tar.gz)      | [tar.gz](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-linux-x86_64.tar.gz) [![nightly linux](https://img.shields.io/github/actions/workflow/status/mdmrk/rosebed/ci.yml?branch=main&event=schedule&label=linux)](https://github.com/mdmrk/rosebed/actions/workflows/ci.yml)  |
| `x86_64-windows`    | [zip](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-windows-x86_64.zip)          | [zip](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-windows-x86_64.zip) [![nightly windows](https://img.shields.io/github/actions/workflow/status/mdmrk/rosebed/ci.yml?branch=main&event=schedule&label=windows)](https://github.com/mdmrk/rosebed/actions/workflows/ci.yml)  |
| `aarch64-macos`     | [tar.gz](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-macos-aarch64.tar.gz)     | [tar.gz](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-macos-aarch64.tar.gz) [![nightly macos](https://img.shields.io/github/actions/workflow/status/mdmrk/rosebed/ci.yml?branch=main&event=schedule&label=macos)](https://github.com/mdmrk/rosebed/actions/workflows/ci.yml) |
| `wasm32-emscripten` | [tar.gz](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-wasm32-emscripten.tar.gz) | [tar.gz](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-wasm32-emscripten.tar.gz) [![nightly web](https://img.shields.io/github/actions/workflow/status/mdmrk/rosebed/ci.yml?branch=main&event=schedule&label=web)](https://github.com/mdmrk/rosebed/actions/workflows/ci.yml) |
| `aarch64-android`   | [apk](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-android-aarch64.apk)         | [apk](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-android-aarch64.apk) [![nightly android](https://img.shields.io/github/actions/workflow/status/mdmrk/rosebed/ci.yml?branch=main&event=schedule&label=android)](https://github.com/mdmrk/rosebed/actions/workflows/ci.yml) |

```sh
# Client
./rosebed

# Server
./rosebed-server [--port 25565] [--world world] [--seed <n>] [--ticks <n>]
```

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/).

```sh
# Build
zig build fetch-assets            # once, before anything else
zig build -Doptimize=ReleaseFast  # binaries into zig-out/bin

# Other useful commands
zig build                         # debug build may be too slow to play
zig build run                     # build and run the client
zig build run-server              # build and run the dedicated server
zig build test                    # run the unit tests
```

Assets aren't in the repo, so `fetch-assets` has to run first. It downloads the official b1.7.3 client jar, checks its SHA-1 and unpacks it into `src/assets/` to be embedded into the binary.

Anything after `--` is passed to the program: `zig build run-server -- --port 25566 --world test`.

### Web

Needs [emscripten](https://emscripten.org/docs/getting_started/downloads.html) on `PATH` and a patched copy of the Zig stdlib:

```sh
lib_dir=$(zig env | sed -n 's/^ *\.lib_dir = "\(.*\)",$/\1/p')
cp -r "$lib_dir" ziglib
chmod -R u+w ziglib
patch -p1 -d ziglib < .github/zig-emscripten.patch

zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseFast \
  --sysroot "$(em-config CACHE)/sysroot" --zig-lib-dir ziglib
```

Output is a static site in `zig-out/www`. You can serve it with `python -m http.server`.

### Android

Needs the [Android NDK](https://developer.android.com/ndk/downloads) and an Android SDK with `build-tools` and a platform installed, plus `zip` and `keytool` on `PATH`. SDL3 itself is the official prebuilt Android build, not compiled from source:

```sh
zig build fetch-android-sdl       # once, unpacks SDL3 and its Java glue into android/sdl

zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseFast \
  -Dandroid-ndk="$ANDROID_NDK_HOME" -Dandroid-sdk="$ANDROID_HOME"
```

The NDK and SDK paths also come from `ANDROID_NDK_HOME`/`ANDROID_NDK_ROOT` and `ANDROID_HOME`/`ANDROID_SDK_ROOT` when the options are left out. `-Dandroid-api` (default 21), `-Dandroid-build-tools` (default `35.0.0`) and `-Dandroid-platform` (default `android-35`) pick the levels to build against.

Output is a signed debug APK in `zig-out/rosebed.apk`. `zig build run` with the same options installs it on a connected device over `adb` and starts it.

## License

GPLv3. See [LICENSE](LICENSE). Not affiliated with or endorsed by Mojang or Microsoft.
