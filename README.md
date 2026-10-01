# Strumline

A Clone Hero–style rhythm game for iOS, written from scratch in Swift (SwiftUI + AVAudioEngine), built on Linux with xtool. Original code, name and art; it plays the same song formats.

## Songs
- Song folders: `song.ini` + `notes.chart` / `notes.mid` + stems (`song`, `guitar`, `bass`, `rhythm`, `keys`, `drums[_1-4]`, `vocals[_1-2]`, `crowd`, `preview`) in `.opus` / `.ogg` (Vorbis **or** Opus) / `.mp3` / `.wav` / `.m4a`.
- `.sng` packages (SngFileFormat v1).
- Put songs in *On My iPhone › Strumline › Songs*, or **Library → Link a Folder / Link .sng Files** to read them in place from iCloud Drive, USB drives, network shares, or other apps (security-scoped bookmarks; iCloud placeholders are downloaded automatically).

## Parts
5-fret guitar / co-op / rhythm / bass / keys, 6-fret (GHL) guitar / bass / rhythm / co-op, drums (4-lane, 4-lane Pro, 5-lane, with conversion between them). Easy–Expert, 2x kick.

## Gameplay (Clone Hero rules)
140 ms hit window, natural HOPOs (`.chart` 65/192 res, `.mid` res/3+1, `hopo_frequency` / `eighthnote_hopo`), forced notes, taps, opens, anchoring, strum/HOPO leniency, sustains (25 pts/beat, `.mid` 1/12 cutoff, `sustain_cutoff_threshold`), star power (phrases, whammy, 8-bar drain, drum fills), solos (+100/note), 4x multiplier (6x bass), stars, per-section stats, practice mode (section loop + speed).

Modifiers: Precision, Drunk, Brutal, Dropless Sustains, Strumless HOPOs, Double Notes, No/Deadly Ghosting, All Strums/HOPOs/Taps/Opens, HOPOs→Taps, Mirror, Note Shuffle, Auto Strum (scores still saved, unlike Clone Hero), Lights Out, Modchart Full/Lite/Prep; drums: Deadly Dynamics, 2x Kick, No Kick, Only Kicks. Song speed 25–300 %, track (note) speed, highway length.

## Input
Touch (tap lanes, or frets + strum bar; flick phone for star power), hardware keyboard, game controllers (anything iOS exposes as a GCController — guitars/adapters in XInput/Switch mode, gamepads), CoreMIDI drum kits (USB/Bluetooth, velocity for dynamics). Everything is rebindable in **Settings › Controls**.

## Layout
- `Sources/StrumCore` — platform-independent: `.chart`/`.mid`/`.sng`/`song.ini` parsing, tempo map, engine, modifiers, Ogg Vorbis (stb_vorbis) + Ogg Opus (libopus 1.5.2) + WAV decoders, lock-free stem mixer.
- `Sources/Strumline` — iOS app.
- `Tools/check` — Linux harness: `swift build --build-system native -c release && .build/release/corecheck <songs…>` parses, bot-plays every part (expects full combos), decodes every stem with a seek check, diffs `.chart` vs `.mid`.
- `Tools/demo/make_demo.py` — generates the bundled original demo song (`uv run --with numpy python make_demo.py OUT`), plus `.mid` and `.sng` fixtures.

## Build / install
`./install.sh` (= `xtool dev`, iPhone on USB, unlocked). `xtool dev build -c release` to build only.

## License
MIT — see `LICENSE`. Bundled third-party code keeps its own license: libopus 1.5.2 (BSD-3-Clause, `Sources/COpus/COPYING`) and stb_vorbis (MIT / public domain, at the end of `Sources/CStbVorbis/stb_vorbis.c`). Strumline is not affiliated with Clone Hero.
