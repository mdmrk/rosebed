# Rosebed

A from-scratch reimplementation of Minecraft Beta 1.7.3 in Zig, using SDL3 and OpenGL 3.3 core.

Includes a client and a dedicated server. Both speak the Beta 1.7.3 network protocol (version 14).

## Play

[**Play in the browser**](https://mdmrk.github.io/rosebed/)

### Download

| Platform | Release | Nightly |
| --- | --- | --- |
| Linux x86_64 | [tar.gz](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-linux-x86_64.tar.gz) | [tar.gz](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-linux-x86_64.tar.gz) |
| Windows x86_64 | [zip](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-windows-x86_64.zip) | [zip](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-windows-x86_64.zip) |
| macOS aarch64 | [tar.gz](https://github.com/mdmrk/rosebed/releases/latest/download/rosebed-macos-aarch64.tar.gz) | [tar.gz](https://github.com/mdmrk/rosebed/releases/download/nightly/rosebed-macos-aarch64.tar.gz) |

All builds are on the [releases page](https://github.com/mdmrk/rosebed/releases). Nightlies are built from the latest commit; the `nightly` tag is replaced on every build.

Run `rosebed` for the client, `rosebed-server` for the dedicated server.

## Server

```
rosebed-server [--port 25565] [--world world] [--seed <n>] [--ticks <n>]
```

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/).

```
zig build fetch-assets   # downloads the official b1.7.3 client jar and extracts its assets
zig build run            # client
zig build run-server     # dedicated server
zig build test
```

Assets are not distributed with the source; `fetch-assets` pulls them from Mojang's servers into `src/assets/`.

## License

GPLv3. See [LICENSE](LICENSE).

Not affiliated with or endorsed by Mojang or Microsoft.
