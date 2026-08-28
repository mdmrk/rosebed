# Rosebed

[![ci](https://github.com/mdmrk/rosebed/actions/workflows/ci.yml/badge.svg)](https://github.com/mdmrk/rosebed/actions/workflows/ci.yml)
[![license](https://img.shields.io/github/license/mdmrk/rosebed)](LICENSE)

A from-scratch reimplementation of Minecraft Beta 1.7.3 in Zig, using SDL3 and OpenGL 3.3.

Includes a client and a dedicated server. Both speak the Beta 1.7.3 network protocol (version 14).

- [Play in the browser](#play-in-the-browser)
- [Download](#download)
- [Server](#server)
- [Build](#build)
  - [Web](#web)
- [License](#license)

## Play in the browser

[mdmrk.github.io/rosebed](https://mdmrk.github.io/rosebed/) is the client built for WebAssembly. Worlds are saved in browser storage. Needs WebGL2.

## Download

| Platform       | Release                                                                                              | Nightly                                                                                               |
| -------------- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Linux x86_64   | [tar.gz](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-linux-x86_64.tar.gz)      | [tar.gz](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-linux-x86_64.tar.gz)      |
| Windows x86_64 | [zip](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-windows-x86_64.zip)          | [zip](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-windows-x86_64.zip)          |
| macOS aarch64  | [tar.gz](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-macos-aarch64.tar.gz)     | [tar.gz](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-macos-aarch64.tar.gz)     |
| Web wasm32     | [tar.gz](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-wasm32-emscripten.tar.gz) | [tar.gz](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-wasm32-emscripten.tar.gz) |

Each archive has both binaries, `rosebed` and `rosebed-server`. All builds are on the [releases page](https://github.com/mdmrk/rosebed/releases). Nightlies are built from the latest commit; the assets on the `nightly` release are replaced on every build.

## Server

```
rosebed-server [--port 25565] [--world world] [--seed <n>] [--ticks <n>]
```

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/). SDL3 and the GL bindings come from the package manager, nothing else to install.

Assets aren't in the repo. **Fetch them first**:

```
zig build fetch-assets
```

That downloads the official b1.7.3 client jar, checks its SHA-1 and unpacks it. Textures, lang files and short sounds land in `src/assets/` and get embedded into the binary; music and records land in `zig-out/bin/resources/`.

```
zig build run
zig build run-server
zig build test
zig build -Doptimize=ReleaseFast
```

Anything after `--` goes to the program: `zig build run-server -- --port 25566 --world test`.

### Web

Needs [emscripten](https://emscripten.org/docs/getting_started/downloads.html) on `PATH` and a patched copy of the Zig stdlib:

```
lib_dir=$(zig env | sed -n 's/^ *\.lib_dir = "\(.*\)",$/\1/p')
cp -r "$lib_dir" ziglib
chmod -R u+w ziglib
patch -p1 -d ziglib < .github/zig-emscripten.patch
```

Then:

```
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseFast \
  --sysroot "$(em-config CACHE)/sysroot" \
  --zig-lib-dir ziglib
```

Output is a static site in `zig-out/www`. Serve it over HTTP, `file://` won't work.

## License

GPLv3. See [LICENSE](LICENSE).

Not affiliated with or endorsed by Mojang or Microsoft.
