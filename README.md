# Rosebed

[![ci](https://github.com/mdmrk/rosebed/actions/workflows/ci.yml/badge.svg)](https://github.com/mdmrk/rosebed/actions/workflows/ci.yml)
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
- [License](#license)

## Not in b1.7.3

The short list of things b1.7.3 does not have. Everything else is meant to match it, and anything that doesn't is a bug.

- [x] **Chat and commands in single player.** `/help`, `/freecam`, `/give`, `/kill`, `/spawn`, `/seed`, `/time`, `/tp`, `/weather`.
- [x] **Chat input editing.** History recall, ctrl+backspace, paste.
- [x] **Fullscreen in Video Settings.** Vanilla has F11 and no setting.

## Play

[Play browser build](https://mdmrk.github.io/rosebed/). Worlds are saved in browser storage. Needs WebGL2.

Or download a build, each archive has both binaries, `rosebed` and `rosebed-server`:

| Platform                  | Release                                                                                              | Nightly                                                                                               |
| ------------------------- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `x86_64-linux`     | [tar.gz](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-linux-x86_64.tar.gz)      | [tar.gz](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-linux-x86_64.tar.gz)      |
| `x86_64-windows` | [zip](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-windows-x86_64.zip)          | [zip](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-windows-x86_64.zip)          |
| `aarch64-macos`    | [tar.gz](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-macos-aarch64.tar.gz)     | [tar.gz](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-macos-aarch64.tar.gz)     |
|  `wasm32-emscripten`  | [tar.gz](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-wasm32-emscripten.tar.gz) | [tar.gz](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-wasm32-emscripten.tar.gz) |

```
rosebed-server [--port 25565] [--world world] [--seed <n>] [--ticks <n>]
```

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/). SDL3 and the GL bindings come from the package manager, nothing else to install.

```
# Build
zig build fetch-assets            # once, before anything else
zig build -Doptimize=ReleaseFast  # binaries into zig-out/bin

zig build                         # debug build may be too slow to play
zig build run                     # build and run the client
zig build run-server              # build and run the dedicated server
zig build test                    # run the unit tests
```

Assets aren't in the repo, so `fetch-assets` has to run first. It downloads the official b1.7.3 client jar, checks its SHA-1 and unpacks it into `src/assets/` to be embedded into the binary, music and records into `zig-out/bin/resources/`.

Anything after `--` is passed to the program: `zig build run-server -- --port 25566 --world test`.

### Web

Needs [emscripten](https://emscripten.org/docs/getting_started/downloads.html) on `PATH` and a patched copy of the Zig stdlib:

```
lib_dir=$(zig env | sed -n 's/^ *\.lib_dir = "\(.*\)",$/\1/p')
cp -r "$lib_dir" ziglib
chmod -R u+w ziglib
patch -p1 -d ziglib < .github/zig-emscripten.patch

zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseFast \
  --sysroot "$(em-config CACHE)/sysroot" --zig-lib-dir ziglib
```

Output is a static site in `zig-out/www`. Serve it over HTTP, `file://` won't work.

## License

GPLv3. See [LICENSE](LICENSE). Not affiliated with or endorsed by Mojang or Microsoft.
