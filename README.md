# Rosebed

[![license](https://img.shields.io/github/license/mdmrk/rosebed)](LICENSE)
[![ci](https://img.shields.io/github/actions/workflow/status/mdmrk/rosebed/ci.yml?branch=main)](https://github.com/mdmrk/rosebed/actions/workflows/ci.yml)

Minecraft Beta 1.7.3 rewritten from scratch in Zig, with a client and a dedicated server. The goal is to match the original: same behavior, same worlds from the same seed, and multiplayer that works with it.

> [!IMPORTANT]
> Most of the game is playable. Anything that behaves differently from the real b1.7.3 is a bug. If you find one, [open an issue](https://github.com/mdmrk/rosebed/issues) saying what you did and what the original does instead.

## Play

**[Play in the browser](https://mdmrk.github.io/rosebed/)**

Or download a build:

| Platform | Stable | Nightly |
| --- | --- | --- |
| Linux (x86_64) | [tar.gz](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-x86_64-linux.tar.gz) | [tar.gz](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-x86_64-linux.tar.gz) |
| Windows (x86_64) | [zip](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-x86_64-windows.zip) | [zip](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-x86_64-windows.zip) |
| macOS (arm64) | [tar.gz](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-aarch64-macos.tar.gz) | [tar.gz](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-aarch64-macos.tar.gz) |
| Web | [tar.gz](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-wasm32-emscripten.tar.gz) | [tar.gz](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-wasm32-emscripten.tar.gz) |
| Android (arm64) | [apk](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-aarch64-linux-android.apk) | [apk](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-aarch64-linux-android.apk) |
| iOS (arm64) | [ipa](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-aarch64-ios.ipa) | [ipa](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-aarch64-ios.ipa) |

```sh
./rosebed                                                              # client
./rosebed-server [--port 25565] [--world world] [--seed <n>] [--ticks <n>]  # server
```

### Extras not in b1.7.3

- Chat and commands in single player: `/help`, `/freecam`, `/give`, `/kill`, `/spawn`, ...
- Chat input editing: history, ctrl+backspace, paste.
- A fullscreen option in Video Settings (vanilla only has F11).
- Touch controls and auto-jump on Android and iOS.

## Build

You need [Zig 0.17.0](https://ziglang.org/download/).

```sh
zig build fetch-assets      # once: downloads the game assets
zig build -Doptimize=fast   # builds into zig-out/bin
```

Other commands:

```sh
zig build run                # run the client
zig build run-server         # run the server
zig build test               # run the tests
zig build run-server -- --port 25566   # pass arguments after --
```

Debug builds (plain `zig build`) may be too slow to play.

### Web

You need [emscripten](https://emscripten.org/docs/getting_started/downloads.html) and a patched copy of the Zig standard library:

```sh
cp -r "$(zig env | sed -n 's/^ *\.lib_dir = "\(.*\)",$/\1/p')" ziglib
chmod -R u+w ziglib
patch -p1 -d ziglib < .github/zig-emscripten.patch

sysroot="$(em-config CACHE)/sysroot"
ZIG_LIB_DIR="$PWD/ziglib" zig build -Dtarget=wasm32-emscripten -Doptimize=fast \
  --sysroot "$sysroot" -Demscripten-sysroot="$sysroot"
```

The site ends up in `zig-out/www`.

### Android

You need the [Android NDK](https://developer.android.com/ndk/downloads), the Android SDK (with build-tools and a platform), `zip` and `keytool`.

```sh
zig build fetch-android-sdl   # once: downloads SDL3
zig build -Dtarget=aarch64-linux-android -Doptimize=fast \
  -Dandroid-ndk="$ANDROID_NDK_HOME" -Dandroid-sdk="$ANDROID_HOME"
```

If `ANDROID_NDK_HOME` and `ANDROID_HOME` are set, you can leave out the two `-D` options.

### iOS

You need macOS with Xcode, and `zip`.

```sh
zig build fetch-ios-sdl   # once: downloads SDL3
zig build -Dtarget=aarch64-ios -Doptimize=fast
```

## License

GPLv3, see [LICENSE](LICENSE). Not affiliated with Mojang or Microsoft.
