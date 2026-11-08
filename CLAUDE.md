# CLAUDE.md

AirScreen is a Windows-only AirPlay screen-mirroring receiver (iPhone → PC). It's a native Win32 C++17 app on top of a vendored, locally patched copy of UxPlay's protocol library. GPL-3.0.

## Build

Windows only (CMake fails with a fatal error on any other platform). You need VS 2022 with the Desktop C++ workload, CMake, and OpenSSL ≥ 1.1.1 (Shining Light `ShiningLight.OpenSSL.Dev`, vcpkg, or `OPENSSL_ROOT_DIR`).

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build.ps1
```

- `scripts/fetch-deps.ps1` (run by `build.ps1`) downloads the BtbN FFmpeg GPL shared build into `third_party/prebuilt/ffmpeg` (gitignored). It skips the download if that folder already exists.
- The build writes `build/Release/AirScreen.exe`. Post-build steps copy the FFmpeg and OpenSSL DLLs next to it.
- To rebuild after the first configure: `cmake --build build --config Release`.
- To build the installer, run Inno Setup on `scripts/airscreen.iss` with `/DCrtDir=<...\x64\Microsoft.VC143.CRT>` and `/DMyAppVersion=<x.y.z>`. The output goes to `out/installer/`.
- CI (`.github/workflows/build.yml`) builds on every push or PR to `main`. Pushing a `v*` tag publishes a GitHub release with `SHA256SUMS.txt`. Untagged builds use version `0.0.0`.

There are no automated tests. To verify a change, build it, run it, and mirror from a real iPhone on the same network. Logs go to `%APPDATA%\AirScreen\airscreen.log`.

## Architecture

| File | Role |
|---|---|
| `src/main.cpp` | `wWinMain`, the main window, the video child window, the settings button, the tray icon, fullscreen, timers, and the rename dialog. Global state lives in the `App` struct (`g_app`). |
| `src/ui.cpp` | `ShellUi`: GDI+ drawing of the idle "ambient field" screen (light/dark), hit-testing, and icons. It doesn't use `airscreen_types.h`. |
| `src/receiver.cpp` | `Receiver`: owns the UxPlay `raop_t` and the `dnssd_t` handle, and holds the C callback thunks (`cb_*` → `Receiver::on_*`). It routes audio and video into the pipelines and writes the log file. |
| `src/video.cpp` | `VideoPipeline`: FFmpeg H.264 decoding with D3D11VA hardware acceleration on a worker thread with a bounded queue (`kMaxQueued = 6`). Frames are presented as NV12 through a D3D11 swapchain and HLSL shaders, with letterbox or cover modes and a per-frame full/limited YUV range. |
| `src/audio.cpp` | `AudioPipeline`: AAC/ALAC decoding through FFmpeg and swresample into a ring buffer, played by a shared-mode WASAPI render thread with a fixed rebuffer cushion. |
| `src/settings.cpp` | Reads and writes `%APPDATA%\AirScreen\settings.ini`, the `airplay.key` pairing key, log rotation (2 MB → `.old`), the Start with Windows Run key, MAC lookup, and the firewall rule. |
| `src/openssl_applink.c` | OpenSSL applink. The EXE exports `OPENSSL_Applink` (a linker flag). |

**Threading.** UxPlay callbacks run on network threads. The receiver never touches UI state directly. It calls `ui_(UiEvent, msg)`, which `App::post_ui` turns into `PostMessageW(WM_AIR_EVENT)` with a heap-allocated `std::string` in `lParam`. The main window procedure deletes that string. Video decoding has its own worker thread, and audio playback runs on a WASAPI event thread. Keep new cross-thread communication on this same posted-message pattern.

**Third-party code**
- `third_party/uxplay/lib`: RAOP/AirPlay, FairPlay (`playfair`), `llhttp`, and the built-in `mdnsd` mDNS responder. There is no Bonjour dependency. **This copy is patched locally** (latency, RTP mirror, raop_buffer resend handling, netutils). Don't replace it wholesale with upstream. Keep patches small and mention them in commit messages.
- `third_party/libplist`: compiled statically without libxml2. Its `config.h` is committed on purpose.
- `third_party/win_compat`: POSIX shims (`pthread.h`, `unistd.h`, `sys/`, `win_compat.c`). `airscreen_types.h` is force-included (`/FI`) into the UxPlay and libplist targets and into every `src/*.cpp` except `ui.cpp`.

## Things that are easy to break

- **Shutdown order:** in `Receiver::stop`, the mDNS goodbye must be sent before `raop_destroy`, because `raop_destroy` calls `WSACleanup`.
- **Fixed ports:** TCP 7000 (AirPlay HTTP) and 7100 (mirror), and UDP 6000, 6001, and 7011. They're fixed so that iOS can reconnect after a crash. If 7000 is busy, the code falls back to an ephemeral port.
- **AirPlay feature bits:** they're set in `Receiver::apply_features`. Bit 42 (H.265) is off because the receiver handles H.264 only. Changing these bits changes what iOS will try to negotiate.
- **Installer DLL list:** `airscreen.iss` lists the shipped DLLs explicitly (avcodec, avutil, swresample, libcrypto, and the VC runtime). If you link a new FFmpeg or OpenSSL library, add it there too, or the installed app won't start. CI enforces this with `scripts/check-installer-dlls.ps1`; run it locally after a Release build.
- **Strings:** the app builds with `UNICODE`. Win32 calls use wide strings, and settings and protocol data use UTF-8 `std::string`. Convert with `MultiByteToWideChar` / `WideCharToMultiByte`. Sources compile with `/utf-8`.
- **Firewall rule:** there's one firewall rule, named `AirScreen`. Both the installer and `ensure_firewall_rule()` manage it, so keep the name identical in both places.

## Conventions

- Code lives in `namespace airscreen`, with an anonymous namespace for file-local helpers. Names use `snake_case`, and members have a trailing underscore (`video_`).
- FFmpeg, WASAPI, and UxPlay handles are stored as `void *` in the headers so that those headers stay free of third-party includes. Cast them in the `.cpp` files.
- Use 4-space indentation, braces on the same line, and always brace `if` bodies.
- Commit messages are short imperative sentences (for example, "Send the mDNS goodbye before tearing down RAOP"). User-facing docs live in `README.md`, so don't add design-notes files to the repo.
