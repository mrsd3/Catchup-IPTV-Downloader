# Catchup — IPTV Catch-up Downloader for macOS

**English** · [Français](README.fr.md)

A native macOS app (SwiftUI) to download catch-up recordings (`tv_archive`) from an IPTV
subscription compatible with **Xtream Codes**, picking shows straight from the TV guide.

![Catchup: channel list and TV guide](docs/catchup-v1.png)

> Catchup is only a client: it does not provide any channels or subscription. You need your own
> credentials from a provider, and you are responsible for respecting the rights of the content
> you download.

## Features

- **TV guide**: pick a show in the EPG and click ⬇︎ — no need to type times.
- **Margins** before/after (2 and 5 min by default) so you never miss the beginning or the end.
- **Custom time range** when the provider has no guide.
- **Downloads** in a toolbar popover (like a web browser): parallel queue (1 to 4), progress,
  speed, stop/retry, FFmpeg log.
- **MP4 files that play everywhere**: video copied losslessly, audio converted to AAC (QuickTime
  can't play the MP2 audio used by broadcast TV), start trimmed to the first frame (no black screen).
- **Categories, search, favorites**, "with catch-up" filter.
- **Server time offset** detected automatically from the EPG (fixes recordings shifted by an hour).
- Automatic FFmpeg reconnection if the stream drops, notification when done.
- **English and French**: follows the macOS language, can be changed in Settings → General.

## Installation

### Ready-made app

1. Download `Catchup.zip` from the [Releases](../../releases), unzip it and drag `Catchup.app`
   into **Applications**.
2. Install FFmpeg (required): `brew install ffmpeg` (see [Homebrew](https://brew.sh)).
3. On first launch, macOS blocks the app because it isn't notarized by Apple:
   open **System Settings → Privacy & Security**, then click **Open Anyway**. Only once.

Requires macOS 14 Sonoma or later, on Apple Silicon and Intel Macs.

### From source

Requirements: Xcode 15+ or the Command Line Tools (`xcode-select --install`), and FFmpeg.

```bash
./build_app.sh              # → build/Catchup.app (current Mac's architecture)
./build_app.sh --install    # → also copies it to /Applications
./build_app.sh --release    # → universal app + build/Catchup.zip to attach to a release
```

For development: `swift run` launches the app directly, or `open Package.swift` to open it in Xcode.

## Settings (⌘,)

- **General**: app language (system, English or French).
- **Server**: address, credentials, catch-up URL format (if downloads fail, try another format),
  detected time offset.
- **Downloads**: destination folder (`~/Downloads` by default), margins, FFmpeg path.

The configuration is stored in `~/.catchup_config.json` (compatible with the
`catchup_downloader.py` script: if you already used it, the app starts already connected).
This file contains your credentials: don't share it.

## File names

```
ChannelName_2026-10-28_2055-2250_Program_title.mp4
```

## Translations

French is the base language of the code; the English translation lives in
`Resources/en.lproj/Localizable.strings`. To add a language, copy that file into
`Resources/<code>.lproj/`, translate the right-hand side, and add the code to
`CFBundleLocalizations` in `Sources/CatchupDownloader/Info.plist`.

## License

[MIT](LICENSE)
