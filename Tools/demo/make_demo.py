#!/usr/bin/env python3
"""Generates Strumline's bundled demo song: an original synthesized track
with separate guitar/bass/drums/backing stems, charted in .chart, .mid and
.sng form. The audio is rendered from the chart events, so a missed note
really does go silent when the guitar stem is muted.

Run:  uv run --with numpy python make_demo.py OUT_DIR
"""
import math, os, struct, subprocess, sys, random
import numpy as np

OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
SR = 44100
BPM = 140
RES = 192
BAR = RES * 4
SEC_PER_TICK = 60 / BPM / RES
random.seed(7)

# ---------------------------------------------------------------- song form
FORM = [("Intro", 4), ("Verse 1", 8), ("Chorus 1", 8), ("Solo", 8), ("Verse 2", 8), ("Chorus 2", 8), ("Outro", 4)]
PROG = ["Em", "C", "G", "D"]
ROOT = {"Em": 40, "C": 36, "G": 43, "D": 38}          # MIDI pitch of chord root (low)
TRIAD = {"Em": [0, 7, 12, 15, 19], "C": [0, 7, 12, 16, 19], "G": [0, 7, 12, 16, 19], "D": [0, 7, 12, 16, 21]}
CHORD_LANES = {"Em": (0, 1), "C": (2, 3), "G": (1, 2), "D": (3, 4)}

sections = []
bar = 0
for name, n in FORM:
    sections.append((name, bar * BAR, n))
    bar += n
TOTAL_BARS = bar
END_TICK = TOTAL_BARS * BAR + BAR

def chord_at(tick):
    return PROG[(tick // BAR) % 4]

# Guitar gem: dict(tick, lanes, length, force, tap)
def guitar_expert():
    ev = []
    for name, start, n in sections:
        for b in range(n):
            t0 = start + b * BAR
            ch = chord_at(t0)
            lo, hi = CHORD_LANES[ch]
            if name == "Intro":
                ev.append(dict(tick=t0, lanes=[lo, hi], length=BAR - RES, force=None, tap=False))
                ev.append(dict(tick=t0 + 3 * RES, lanes=[lo], length=0, force=None, tap=False))
                ev.append(dict(tick=t0 + 3 * RES + RES // 2, lanes=[hi], length=0, force=None, tap=False))
            elif name.startswith("Verse"):
                # 8th-note riff with 16th hammer-on pairs on beats 2 and 4
                pat = [lo, lo, hi, lo, lo, lo, hi, min(4, hi + 1)]
                for i, lane in enumerate(pat):
                    t = t0 + i * RES // 2
                    ev.append(dict(tick=t, lanes=[lane], length=0, force=None, tap=False))
                    if i in (2, 6):
                        ev.append(dict(tick=t + RES // 4, lanes=[max(0, lane - 1)], length=0, force=None, tap=False))
                if b % 4 == 3:
                    # forced strum on a note that would naturally be a HOPO
                    ev[-1]["force"] = "strum"
            elif name.startswith("Chorus"):
                for i in range(8):
                    t = t0 + i * RES // 2
                    if i == 0:
                        ev.append(dict(tick=t, lanes=[lo, hi], length=RES * 2 - 24, force=None, tap=False))
                    elif i >= 4:
                        ev.append(dict(tick=t, lanes=[lo, hi] if i % 2 == 0 else [hi], length=0, force=None, tap=False))
            elif name == "Solo":
                if b < 4:
                    # 16th-note runs (natural HOPOs after the first)
                    run = [0, 1, 2, 3, 4, 3, 2, 1] if b % 2 == 0 else [4, 3, 2, 1, 0, 1, 2, 3]
                    for i in range(16):
                        ev.append(dict(tick=t0 + i * RES // 4, lanes=[run[i % 8]], length=0, force=None, tap=False))
                elif b < 6:
                    # tapping section
                    taps = [4, 2, 0, 2]
                    for i in range(16):
                        ev.append(dict(tick=t0 + i * RES // 4, lanes=[taps[i % 4]], length=0, force=None, tap=True))
                else:
                    # open-note gallop then a sustained bend
                    for i in range(6):
                        ev.append(dict(tick=t0 + i * RES // 2, lanes=[7], length=0, force=None, tap=False))
                    ev.append(dict(tick=t0 + 3 * RES, lanes=[hi], length=RES - 24, force="hopo", tap=False))
            elif name == "Outro":
                if b < 3:
                    ev.append(dict(tick=t0, lanes=[7], length=BAR - RES, force=None, tap=False))
                else:
                    ev.append(dict(tick=t0, lanes=[0, 2, 4], length=BAR - 48, force=None, tap=False))
    return ev

def reduce(ev, level):
    """Lower difficulties: fewer notes, smaller chords, fewer lanes."""
    out = []
    maxlane = {3: 4, 2: 3, 1: 2}[level]
    grid = {3: RES // 2, 2: RES // 2, 1: RES}[level]
    for e in ev:
        if e["tick"] % grid != 0:
            continue
        if level == 1 and 7 in e["lanes"]:
            e = dict(e, lanes=[0])
        lanes = [l if l == 7 else min(l, maxlane) for l in e["lanes"]]
        lanes = sorted(set(lanes))
        if level <= 2:
            lanes = lanes[:1] if level == 1 else lanes[:2]
        out.append(dict(e, lanes=lanes, tap=e["tap"], force=None if level < 3 else e["force"]))
    return out

def bass_expert():
    ev = []
    for name, start, n in sections:
        for b in range(n):
            t0 = start + b * BAR
            lane = {"Em": 0, "C": 2, "G": 1, "D": 3}[chord_at(t0)]
            step = RES // 2 if name not in ("Intro", "Outro") else RES
            for i in range(0, BAR, step):
                ln = lane if i % RES == 0 else min(4, lane + 1) if (i // step) % 4 == 3 else lane
                ev.append(dict(tick=t0 + i, lanes=[ln], length=0, force=None, tap=False))
    return ev

# Drums: (tick, lane, cymbal)   lanes: 0 kick 1 red 2 yellow 3 blue 4 green
def drums_expert():
    ev = []
    fills = []
    for si, (name, start, n) in enumerate(sections):
        for b in range(n):
            t0 = start + b * BAR
            last = b == n - 1
            for i in range(8):
                t = t0 + i * RES // 2
                if last and i >= 4 and name != "Outro":
                    # tom fill
                    ev.append((t, [2, 3, 4, 4][i - 4], False))
                    ev.append((t + RES // 4, [2, 3, 3, 4][i - 4], False))
                    continue
                if i == 0 and (b == 0 or name.startswith("Chorus")):
                    ev.append((t, 4, True))      # crash
                elif name.startswith("Chorus") or name == "Solo":
                    ev.append((t, 3, True))      # ride
                else:
                    ev.append((t, 2, True))      # hi-hat
                if i in (0, 3, 4) or (name.startswith("Chorus") and i == 7):
                    ev.append((t, 0, False))
                if i in (2, 6):
                    ev.append((t, 1, False))
            if last and name != "Outro" and si + 1 < len(sections):
                fills.append((t0 + BAR // 2, BAR // 2))  # activation at next downbeat crash
    return ev, fills

G = {3: guitar_expert()}
for lvl in (2, 1, 0):
    G[lvl] = reduce(G[3], max(1, lvl))
B = {3: bass_expert()}
for lvl in (2, 1, 0):
    B[lvl] = reduce(B[3], max(1, lvl))
D3, FILLS = drums_expert()
D = {3: D3, 2: [e for e in D3 if e[0] % (RES // 2) == 0], 1: [e for e in D3 if e[0] % RES == 0 and e[1] != 3], 0: [e for e in D3 if e[0] % RES == 0 and e[1] in (0, 1, 2)]}

# star power: chorus first 2 bars, solo last 2 bars, verse 2 bars 4-5
SP = []
for name, start, n in sections:
    if name.startswith("Chorus"):
        SP.append((start, 2 * BAR))
    if name == "Solo":
        SP.append((start + 6 * BAR, 2 * BAR))
    if name == "Verse 2":
        SP.append((start + 4 * BAR, 2 * BAR))
SOLO = [(s, s + n * BAR - RES // 4) for name, s, n in sections if name == "Solo"]

# ---------------------------------------------------------- HOPO semantics
def natural_kinds(ev):
    """Mirror of ChartBuilder's natural HOPO rule (threshold 65 @ 192)."""
    kinds = []
    prev = None
    for e in ev:
        lanes = e["lanes"]
        mask = sum(1 << (5 if l == 7 else l) for l in lanes)
        hopo = False
        if prev is not None and len(lanes) == 1 and e["tick"] - prev[0] <= 65 and mask != prev[1]:
            hopo = not (prev[2] and (prev[1] & mask))
        kinds.append(hopo)
        prev = (e["tick"], mask, len(lanes) > 1)
    return kinds

# ---------------------------------------------------------------- .chart
def write_chart(path):
    L = ['[Song]', '{', '  Name = "Strumline Demo"', '  Artist = "Strumline"', '  Charter = "Strumline"',
         f'  Resolution = {RES}', '  Offset = 0', '  MusicStream = "song.ogg"', '}',
         '[SyncTrack]', '{', '  0 = TS 4', f'  0 = B {BPM * 1000}', '}', '[Events]', '{']
    for name, start, n in sections:
        L.append(f'  {start} = E "section {name}"')
    L.append(f'  {TOTAL_BARS * BAR} = E "end"')
    L.append('}')
    diffs = ["Easy", "Medium", "Hard", "Expert"]
    for part, data in (("Single", G), ("DoubleBass", B)):
        for lvl in range(4):
            ev = data[lvl]
            nat = natural_kinds(ev)
            lines = []
            for e, h in zip(ev, nat):
                for l in e["lanes"]:
                    lines.append((e["tick"], 0, f'N {l} {e["length"]}'))
                want = {"hopo": True, "strum": False}.get(e["force"], h)
                if want != h:
                    lines.append((e["tick"], 1, 'N 5 0'))
                if e["tap"]:
                    lines.append((e["tick"], 1, 'N 6 0'))
            for s, ln in SP:
                lines.append((s, 2, f'S 2 {ln}'))
            if part == "Single":
                for s, e in SOLO:
                    lines.append((s, 3, 'E solo'))
                    lines.append((e, 3, 'E soloend'))
            lines.sort()
            L += [f'[{diffs[lvl]}{part}]', '{'] + [f'  {t} = {x}' for t, _, x in lines] + ['}']
    for lvl in range(4):
        lines = []
        for t, lane, cym in D[lvl]:
            lines.append((t, 0, f'N {lane} 0'))
            if cym and lane in (2, 3, 4):
                lines.append((t, 1, f'N {64 + lane} 0'))
        for s, ln in SP:
            lines.append((s, 2, f'S 2 {ln}'))
        for s, ln in FILLS:
            lines.append((s, 2, f'S 64 {ln}'))
        lines.sort()
        L += [f'[{diffs[lvl]}Drums]', '{'] + [f'  {t} = {x}' for t, _, x in lines] + ['}']
    open(path, "w", newline="\r\n").write("\n".join(L) + "\n")

# ---------------------------------------------------------------- .mid
def vlq(n):
    b = [n & 0x7F]
    n >>= 7
    while n:
        b.insert(0, (n & 0x7F) | 0x80)
        n >>= 7
    return bytes(b)

def mtrack(name, events):
    """events: list of (tick, order, bytes)"""
    events = sorted(events, key=lambda e: (e[0], e[1]))
    out = b"\x00\xFF\x03" + vlq(len(name)) + name.encode()
    last = 0
    for t, _, data in events:
        out += vlq(t - last) + data
        last = t
    out += b"\x00\xFF\x2F\x00"
    return b"MTrk" + struct.pack(">I", len(out)) + out

def note(t, n, length, vel=100):
    return [(t, 1, bytes([0x90, n, vel])), (t + max(1, length), 0, bytes([0x80, n, 0]))]

def text(t, s):
    return (t, 2, b"\xFF\x01" + vlq(len(s)) + s.encode())

def write_mid(path):
    tempo = [(0, 0, b"\xFF\x51\x03" + struct.pack(">I", int(60_000_000 / BPM))[1:]), (0, 0, b"\xFF\x58\x04\x04\x02\x18\x08")]
    evs = [text(s, f"[section {n}]") for n, s, _ in sections] + [text(TOTAL_BARS * BAR, "[end]")]
    tracks = [mtrack("tempo", tempo), mtrack("EVENTS", evs)]
    for tname, data in (("PART GUITAR", G), ("PART BASS", B)):
        ev = [text(0, "[ENHANCED_OPENS]")]
        for lvl in range(4):
            base = 60 + lvl * 12
            nat = natural_kinds(data[lvl])
            for e, h in zip(data[lvl], nat):
                for l in e["lanes"]:
                    n = base - 1 if l == 7 else base + l
                    ev += note(e["tick"], n, e["length"] if e["length"] >= RES // 3 else 1)
                want = {"hopo": True, "strum": False}.get(e["force"], h)
                if want != h:
                    ev += note(e["tick"], base + (5 if want else 6), 1)
                if e["tap"]:
                    ev += note(e["tick"], 104, 1)
        for s, ln in SP:
            ev += note(s, 116, ln)
        if tname == "PART GUITAR":
            for s, e in SOLO:
                ev += note(s, 103, e - s + 1)
        tracks.append(mtrack(tname, ev))
    ev = []
    for lvl in range(4):
        base = 60 + lvl * 12
        for t, lane, cym in D[lvl]:
            ev += note(t, base + lane, 1)
            if lane in (2, 3, 4) and not cym:
                ev += note(t, 108 + lane, 1)  # tom markers 110/111/112
    for s, ln in SP:
        ev += note(s, 116, ln)
    for s, ln in FILLS:
        for n in range(120, 125):
            ev += note(s, n, ln)
    tracks.append(mtrack("PART DRUMS", ev))
    hdr = b"MThd" + struct.pack(">IHHH", 6, 1, len(tracks), RES)
    open(path, "wb").write(hdr + b"".join(tracks))

# ---------------------------------------------------------------- audio
N = int((END_TICK * SEC_PER_TICK + 2) * SR)

def ts(tick):
    return int(tick * SEC_PER_TICK * SR)

def midi_hz(p):
    return 440 * 2 ** ((p - 69) / 12)

def pluck(freq, dur, bright=0.5, decay=0.996):
    n = int(dur * SR)
    period = max(2, int(SR / freq))
    buf = np.random.uniform(-1, 1, period)
    # Karplus-Strong, vectorised per period
    out = np.empty(n)
    idx = 0
    prev = buf.copy()
    while idx < n:
        k = min(period, n - idx)
        out[idx:idx + k] = prev[:k]
        nxt = decay * (bright * prev + (1 - bright) * np.roll(prev, 1))
        prev = nxt
        idx += k
    env = np.minimum(1, np.arange(n) / (0.002 * SR))
    return out * env

def add(track, start, sig, gain=1.0):
    end = min(len(track), start + len(sig))
    if start < end:
        track[start:end] += sig[: end - start] * gain

def render_guitar(ev, lane_pitch):
    tr = np.zeros(N)
    for e in ev:
        dur = max(0.25, (e["length"] + RES // 2) * SEC_PER_TICK)
        ch = chord_at(e["tick"])
        for l in e["lanes"]:
            p = lane_pitch(ch, l)
            s = pluck(midi_hz(p), dur, bright=0.35, decay=0.9985 if e["length"] else 0.994)
            add(tr, ts(e["tick"]), s, 0.32 / len(e["lanes"]) ** 0.5)
    # mild overdrive
    return np.tanh(tr * 2.2) * 0.45

def gpitch(ch, lane):
    r = ROOT[ch] + 12
    return r - 12 if lane == 7 else r + TRIAD[ch][lane]

def bpitch(ch, lane):
    return ROOT[ch] - 12 + [0, 7, 12, 7, 12][lane if lane < 5 else 0]

def render_bass(ev):
    tr = np.zeros(N)
    for e in ev:
        ch = chord_at(e["tick"])
        p = bpitch(ch, e["lanes"][0])
        dur = RES / 2 * SEC_PER_TICK * 0.95
        t = np.arange(int(dur * SR)) / SR
        f = midi_hz(p)
        sig = (np.sin(2 * np.pi * f * t) + 0.35 * np.sin(4 * np.pi * f * t) + 0.12 * np.sign(np.sin(2 * np.pi * f * t))) * np.exp(-t * 3)
        sig *= np.minimum(1, t / 0.004) * np.minimum(1, (dur - t) / 0.01)
        add(tr, ts(e["tick"]), sig, 0.35)
    return np.tanh(tr * 1.5) * 0.6

def render_drums(ev):
    tr = np.zeros(N)
    rng = np.random.default_rng(3)
    def kick():
        t = np.arange(int(0.35 * SR)) / SR
        f = 45 + 90 * np.exp(-t * 30)
        return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 9)
    def snare():
        t = np.arange(int(0.25 * SR)) / SR
        return (rng.uniform(-1, 1, len(t)) * 0.7 + np.sin(2 * np.pi * 190 * t) * 0.5) * np.exp(-t * 18)
    def hat(open_=False):
        t = np.arange(int(0.12 * SR)) / SR
        n = rng.uniform(-1, 1, len(t))
        n = np.diff(n, prepend=0)
        return n * np.exp(-t * (25 if open_ else 60)) * 0.5
    def crash():
        t = np.arange(int(1.4 * SR)) / SR
        n = np.diff(rng.uniform(-1, 1, len(t)), prepend=0)
        return n * np.exp(-t * 2.5) * 0.45
    def tom(f):
        t = np.arange(int(0.4 * SR)) / SR
        return np.sin(2 * np.pi * np.cumsum(f * (1 + 0.5 * np.exp(-t * 20))) / SR) * np.exp(-t * 7)
    S = {"k": kick(), "s": snare(), "h": hat(), "r": hat(True), "c": crash(), "t2": tom(180), "t3": tom(140), "t4": tom(100)}
    for t, lane, cym in ev:
        key = {0: "k", 1: "s"}.get(lane)
        if key is None:
            key = ("h" if lane == 2 else "r" if lane == 3 else "c") if cym else f"t{lane}"
        add(tr, ts(t), S[key], 0.55)
    return np.tanh(tr * 1.3) * 0.7

def render_backing():
    tr = np.zeros(N)
    for b in range(TOTAL_BARS):
        ch = PROG[b % 4]
        dur = BAR * SEC_PER_TICK
        t = np.arange(int(dur * SR)) / SR
        sig = np.zeros(len(t))
        for iv in (0, 7, 12, 16 if ch != "Em" else 15):
            f = midi_hz(ROOT[ch] + 24 + iv)
            sig += np.sin(2 * np.pi * f * t) + 0.3 * np.sin(2 * np.pi * 2 * f * t + 0.3)
        env = np.minimum(1, t / 0.08) * np.minimum(1, (dur - t) / 0.1)
        add(tr, ts(b * BAR), sig * env, 0.06)
    return tr

def stereo(x, pan=0.0):
    l = x * math.cos((pan + 1) * math.pi / 4)
    r = x * math.sin((pan + 1) * math.pi / 4)
    return np.stack([l, r], axis=1)

def write_wav(path, st):
    data = (np.clip(st, -1, 1) * 32767).astype("<i2").tobytes()
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 2, SR, SR * 4, 4, 16) + b"data" + struct.pack("<I", len(data)) + data)

def encode(wav, out, codec):
    args = ["ffmpeg", "-y", "-loglevel", "error", "-i", wav]
    if codec == "vorbis":
        args += ["-c:a", "libvorbis", "-q:a", "5"]
    else:
        args += ["-c:a", "libopus", "-b:a", "96k", "-f", "ogg" if out.endswith(".ogg") else "opus"]
    subprocess.check_call(args + [out])

# ---------------------------------------------------------------- .sng
def write_sng(folder, out, meta):
    files = [f for f in sorted(os.listdir(folder)) if f != "song.ini"]
    mask = bytes(random.randrange(256) for _ in range(16))
    md = b"".join(struct.pack("<i", len(k.encode())) + k.encode() + struct.pack("<i", len(v.encode())) + v.encode() for k, v in meta.items())
    md = struct.pack("<Q", len(meta)) + md
    blobs = [open(os.path.join(folder, f), "rb").read() for f in files]
    idx_len = 8 + sum(1 + len(f.encode()) + 16 for f in files)
    header = b"SNGPKG" + struct.pack("<I", 1) + mask
    data_start = len(header) + 8 + len(md) + 8 + idx_len + 8
    idx = struct.pack("<Q", len(files))
    off = data_start
    for f, b in zip(files, blobs):
        idx += bytes([len(f.encode())]) + f.encode() + struct.pack("<QQ", len(b), off)
        off += len(b)
    body = b""
    for b in blobs:
        a = np.frombuffer(b, dtype=np.uint8)
        i = np.arange(len(a))
        key = np.frombuffer(mask, dtype=np.uint8)[i & 15] ^ (i & 0xFF).astype(np.uint8)
        body += (a ^ key).tobytes()
    with open(out, "wb") as fh:
        fh.write(header + struct.pack("<Q", len(md)) + md + struct.pack("<Q", idx_len) + idx + struct.pack("<Q", len(body)) + body)

def main():
    song = os.path.join(OUT, "Strumline Demo")
    os.makedirs(song, exist_ok=True)
    tmp = os.path.join(OUT, "tmp")
    os.makedirs(tmp, exist_ok=True)
    print("rendering stems…")
    stems = {
        "guitar": stereo(render_guitar(G[3], gpitch), -0.25),
        "bass": stereo(render_bass(B[3]), 0.1),
        "drums": stereo(render_drums(D[3])),
        "song": stereo(render_backing(), 0.2),
    }
    for k, v in stems.items():
        write_wav(os.path.join(tmp, k + ".wav"), v)
    # A mix of containers/codecs on purpose: Vorbis, Opus-in-.opus, Opus-in-.ogg.
    encode(os.path.join(tmp, "guitar.wav"), os.path.join(song, "guitar.ogg"), "vorbis")
    encode(os.path.join(tmp, "bass.wav"), os.path.join(song, "bass.opus"), "opus")
    encode(os.path.join(tmp, "drums.wav"), os.path.join(song, "drums.ogg"), "opus")
    encode(os.path.join(tmp, "song.wav"), os.path.join(song, "song.ogg"), "vorbis")
    write_chart(os.path.join(song, "notes.chart"))
    length_ms = int(TOTAL_BARS * BAR * SEC_PER_TICK * 1000) + 1500
    ini = {"name": "Strumline Demo", "artist": "Strumline", "album": "Built-in", "genre": "Rock", "year": "2026",
           "charter": "Strumline", "song_length": str(length_ms), "preview_start_time": str(int(sections[2][1] * SEC_PER_TICK * 1000)),
           "diff_guitar": "3", "diff_bass": "2", "diff_drums": "3", "pro_drums": "True",
           "loading_phrase": "Everything you hear was generated from the chart you're about to play."}
    with open(os.path.join(song, "song.ini"), "w") as f:
        f.write("[song]\n" + "".join(f"{k} = {v}\n" for k, v in ini.items()))
    # Test fixtures: the same song as .mid and as .sng
    mid = os.path.join(OUT, "Strumline Demo (mid)")
    os.makedirs(mid, exist_ok=True)
    write_mid(os.path.join(mid, "notes.mid"))
    for f in ("guitar.ogg", "bass.opus", "drums.ogg", "song.ogg", "song.ini"):
        with open(os.path.join(song, f), "rb") as a, open(os.path.join(mid, f), "wb") as b:
            b.write(a.read())
    write_sng(song, os.path.join(OUT, "Strumline Demo.sng"), ini)
    print("done:", song)

main()
