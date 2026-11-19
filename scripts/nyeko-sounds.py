#!/usr/bin/env python3
"""Nyeko's own sounds, made from nothing but maths: soft kalimba plucks, little bells, bubbles and Nyo's chirps.

Writes the 29 WAVs the apps play (48 kHz, 16-bit, stereo) under the names the code asks for:
  NotchBuddy/Resources/sounds/<name>.wav        the Mac app, and the Windows app (vite serves them as /sounds)
  android/app/src/main/res/raw/<name>.wav       the 14 the Android app plays
Each one is levelled to the loudness the apps were tuned for (LEVEL, dB RMS), so nothing gets louder or quieter.

    python3 scripts/nyeko-sounds.py            # needs numpy
"""
import os
import wave

import numpy as np

SR = 48_000
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RNG = np.random.default_rng(7)

# Target loudness per sound, dB RMS (the level each slot in the apps was mixed for).
LEVEL = {
    "annoyed": -30.9, "approval": -23.6, "approve": -28.5, "attach": -26.1, "blip": -41.0, "close": -36.9,
    "dizzy": -25.1, "error": -22.9, "finish": -19.8, "greet": -23.9, "greeting": -26.2, "gulp": -25.8,
    "hover": -49.0, "love": -27.0, "open": -34.8, "peek": -35.0, "pop": -38.4, "proud": -24.1,
    "question": -25.6, "rate": -28.0, "search": -31.8, "send": -36.1, "slap": -32.2, "sleep": -33.5,
    "think": -31.1, "tick": -52.2, "wink": -42.6, "work": -35.6, "yawn": -29.0,
}
ANDROID = ["annoyed", "approval", "dizzy", "error", "finish", "greet", "love", "question", "rate", "search",
           "slap", "sleep", "think", "work"]


# ── building blocks ─────────────────────────────────────────────────────────

def t_of(dur):
    return np.arange(int(SR * dur)) / SR


def note(name):
    """'A4' → Hz."""
    names = {"C": -9, "C#": -8, "D": -7, "D#": -6, "E": -5, "F": -4, "F#": -3, "G": -2, "G#": -1, "A": 0, "A#": 1, "B": 2}
    n, octave = name[:-1], int(name[-1])
    return 440.0 * 2 ** ((names[n] + 12 * (octave - 4)) / 12)


def env(n, attack=0.004, decay=0.25, sustain=0.0, release=0.05, hold=0.0):
    """Attack, exponential decay towards sustain, then release at the end."""
    t = np.arange(n) / SR
    a = np.clip(t / max(attack, 1e-4), 0, 1)
    d = sustain + (1 - sustain) * np.exp(-np.maximum(t - attack - hold, 0) / max(decay, 1e-4))
    r = np.clip((n / SR - t) / max(release, 1e-4), 0, 1)
    return a * d * r


def phase(freq):
    """Phase of a (possibly gliding) frequency array."""
    return 2 * np.pi * np.cumsum(freq) / SR


def kalimba(f, dur=0.6, bright=1.0):
    t = t_of(dur)
    n = len(t)
    x = np.sin(2 * np.pi * f * t) * env(n, 0.002, 0.28 * dur + 0.05)
    x += 0.35 * bright * np.sin(2 * np.pi * f * 5.4 * t) * env(n, 0.001, 0.04)      # the tine's metallic click
    x += 0.18 * np.sin(2 * np.pi * f * 2.0 * t) * env(n, 0.002, 0.12)
    return x


def bell(f, dur=0.8, ratio=3.5, index=2.0):
    t = t_of(dur)
    n = len(t)
    mod = index * env(n, 0.001, 0.15) * np.sin(2 * np.pi * f * ratio * t)
    return np.sin(2 * np.pi * f * t + mod) * env(n, 0.002, 0.35 * dur)


def marimba(f, dur=0.35):
    t = t_of(dur)
    n = len(t)
    return (np.sin(2 * np.pi * f * t) + 0.25 * np.sin(2 * np.pi * f * 4 * t) * env(n, 0.001, 0.03)) * env(n, 0.002, 0.09)


def glide(f0, f1, dur, curve=1.0):
    k = np.linspace(0, 1, int(SR * dur)) ** curve
    return f0 * (f1 / f0) ** k


def chirp(f0, f1, dur, vib=0.0, vib_rate=7.0, curve=1.0, harmonics=(1, 0.5, 0.25, 0.12)):
    """Nyo's voice: a gliding tone with a few harmonics and a soft vowel-like tilt (a 'mrrp')."""
    t = t_of(dur)
    f = glide(f0, f1, dur, curve) * (1 + vib * np.sin(2 * np.pi * vib_rate * t))
    ph = phase(f)
    x = sum(a * np.sin((i + 1) * ph) for i, a in enumerate(harmonics))
    return x * env(len(t), 0.015, dur * 0.6, sustain=0.0, release=0.06)


def noise(dur, color=0.0):
    x = RNG.standard_normal(int(SR * dur))
    if color:  # simple low-pass: >0 darker
        a = color
        y = np.zeros_like(x)
        for i in range(1, len(x)):
            y[i] = a * y[i - 1] + (1 - a) * x[i]
        x = y / (np.abs(y).max() + 1e-9)
    return x


def bandpass(x, lo, hi):
    spec = np.fft.rfft(x)
    freqs = np.fft.rfftfreq(len(x), 1 / SR)
    spec[(freqs < lo) | (freqs > hi)] = 0
    return np.fft.irfft(spec, len(x))


def at(total, *parts):
    """Mixes (start_seconds, signal) parts into one buffer of `total` seconds."""
    out = np.zeros(int(SR * total))
    for start, sig in parts:
        i = int(SR * start)
        j = min(len(out), i + len(sig))
        out[i:j] += sig[: j - i]
    return out


def pop_(f0=900, f1=250, dur=0.09):
    t = t_of(dur)
    return np.sin(phase(glide(f0, f1, dur, 0.5))) * env(len(t), 0.001, dur * 0.35)


def click(dur=0.012, f=3200):
    t = t_of(dur)
    return np.sin(2 * np.pi * f * t) * env(len(t), 0.0005, 0.002) + 0.3 * noise(dur) * env(len(t), 0.0003, 0.0015)


# ── the 29 sounds ───────────────────────────────────────────────────────────

def make():
    s = {}
    s["hover"] = at(0.08, (0, click(0.03, 2600)))
    s["tick"] = at(0.07, (0, click(0.02, 4200)))
    s["blip"] = at(0.10, (0, np.sin(2 * np.pi * note("E6") * t_of(0.08)) * env(int(SR * 0.08), 0.002, 0.025)))
    s["wink"] = at(0.21, (0, bell(note("B6"), 0.2, 2.0, 1.2)), (0.04, 0.6 * bell(note("E7"), 0.17, 2.0, 1.0)))
    s["peek"] = at(0.45, (0, kalimba(note("A5"), 0.3)), (0.09, kalimba(note("E6"), 0.36)))
    s["open"] = at(0.5, (0, 0.5 * bandpass(noise(0.25), 1500, 6000) * np.linspace(0, 1, int(SR * 0.25)) ** 2 * env(int(SR * 0.25), 0.2, 1, 1, 0.03)),
                   (0.12, kalimba(note("G5"), 0.38)))
    s["close"] = at(0.43, (0, kalimba(note("E6"), 0.25)), (0.08, kalimba(note("B5"), 0.35)))
    s["work"] = at(0.38, (0, marimba(note("D5"), 0.18)), (0.11, marimba(note("A5"), 0.27)))
    s["pop"] = at(0.38, (0, pop_(1100, 300, 0.08)), (0.07, 0.4 * pop_(1700, 600, 0.06)))
    s["send"] = at(0.48, (0, 0.6 * bandpass(noise(0.3), 800, 5000) * env(int(SR * 0.3), 0.12, 0.08)),
                   (0.0, 0.5 * np.sin(phase(glide(500, 1600, 0.3, 0.7))) * env(int(SR * 0.3), 0.05, 0.12)),
                   (0.22, 0.5 * kalimba(note("C7"), 0.25)))
    s["attach"] = at(0.9, (0, 0.6 * bandpass(noise(0.35), 2000, 9000) * np.abs(np.sin(2 * np.pi * 38 * t_of(0.35))) * env(int(SR * 0.35), 0.02, 0.3, 0.6, 0.05)),
                     (0.38, click(0.03, 1800)), (0.42, kalimba(note("A5"), 0.45)))
    s["approve"] = at(0.6, (0, kalimba(note("C6"), 0.3)), (0.1, kalimba(note("G6"), 0.48)))
    s["approval"] = at(0.88, (0, bell(note("E6"), 0.45, 3.0, 1.6)), (0.16, bell(note("A6"), 0.7, 3.0, 1.6)))
    s["question"] = at(0.7, (0, chirp(380, 760, 0.42, curve=1.6)), (0.32, 0.5 * kalimba(note("B5"), 0.38)))
    s["greet"] = at(0.75, (0, chirp(420, 640, 0.18, vib=0.04, vib_rate=28)), (0.16, chirp(560, 880, 0.32, curve=0.7)),
                    (0.4, 0.4 * bell(note("E7"), 0.3, 2.0, 1.0)))
    s["finish"] = at(1.16, (0, kalimba(note("C6"), 0.5)), (0.11, kalimba(note("E6"), 0.5)), (0.22, kalimba(note("G6"), 0.6)),
                     (0.33, bell(note("C7"), 0.8, 2.0, 1.2)), (0.45, 0.35 * bell(note("G7"), 0.6, 2.0, 0.8)))
    s["proud"] = at(0.86, (0, marimba(note("G5"), 0.2)), (0.12, marimba(note("G5"), 0.2)), (0.24, kalimba(note("D6"), 0.6)),
                    (0.24, 0.6 * kalimba(note("B5"), 0.6)), (0.3, 0.3 * bell(note("D7"), 0.5, 2.0, 1.0)))
    s["error"] = at(0.84, (0, bell(note("D5"), 0.45, 1.5, 1.2)), (0.17, bell(note("A#4"), 0.65, 1.5, 1.4)))
    s["rate"] = at(0.67, (0, chirp(300, 240, 0.6, vib=0.06, vib_rate=9, harmonics=(1, 0.6, 0.3))))
    s["annoyed"] = at(0.59, (0, chirp(260, 170, 0.55, vib=0.08, vib_rate=22, harmonics=(1, 0.7, 0.5, 0.3, 0.2))))
    s["dizzy"] = at(0.98, (0, chirp(700, 350, 0.95, vib=0.12, vib_rate=5.5, harmonics=(1, 0.3))),
                    (0.1, 0.4 * bell(note("E7"), 0.3)), (0.4, 0.3 * bell(note("C7"), 0.3)), (0.7, 0.25 * bell(note("G6"), 0.25)))
    s["slap"] = at(0.6, (0, 0.8 * bandpass(noise(0.05), 300, 4000) * env(int(SR * 0.05), 0.001, 0.012)),
                   (0.01, np.sin(phase(glide(520, 140, 0.45, 0.6) * (1 + 0.05 * np.sin(2 * np.pi * 14 * t_of(0.45))))) * env(int(SR * 0.45), 0.003, 0.18)))
    s["gulp"] = at(0.75, (0, chirp(320, 130, 0.22, harmonics=(1, 0.4))), (0.28, pop_(500, 160, 0.12)),
                   (0.45, 0.5 * pop_(900, 400, 0.07)), (0.55, 0.3 * pop_(1300, 700, 0.05)))
    s["love"] = at(0.79, (0, 0.5 * chirp(330, 360, 0.5, vib=0.05, vib_rate=25, harmonics=(1, 0.6, 0.4))),
                   (0.1, bell(note("A6"), 0.5, 2.0, 1.0)), (0.28, bell(note("C#7"), 0.5, 2.0, 1.0)))
    s["yawn"] = at(0.73, (0, chirp(520, 230, 0.7, curve=0.6, harmonics=(1, 0.3, 0.1))),
                   (0.05, 0.25 * bandpass(noise(0.6), 300, 2500) * env(int(SR * 0.6), 0.2, 0.3)))
    s["think"] = at(0.44, (0, chirp(300, 330, 0.42, vib=0.03, vib_rate=6, harmonics=(1, 0.2))))
    s["search"] = at(0.46, (0, np.sin(phase(glide(900, 1400, 0.4, 0.4))) * env(int(SR * 0.4), 0.004, 0.14)),
                     (0.14, 0.4 * np.sin(phase(glide(900, 1400, 0.3, 0.4))) * env(int(SR * 0.3), 0.004, 0.1)))
    s["sleep"] = at(0.45, (0, 0.6 * bandpass(noise(0.42), 400, 2000) * env(int(SR * 0.42), 0.12, 0.2)),
                    (0.02, 0.6 * chirp(420, 300, 0.38, harmonics=(1, 0.2))))
    # The greeting: a short tune in C major, plucked, with Nyo's chirp at the end.
    tune = [("C6", 0.00), ("E6", 0.24), ("G6", 0.48), ("E6", 0.72), ("A6", 1.08), ("G6", 1.32), ("E6", 1.56),
            ("D6", 1.92), ("E6", 2.16), ("C6", 2.40)]
    parts = [(start, kalimba(note(n), 0.7)) for n, start in tune]
    parts += [(start, 0.35 * marimba(note(b), 0.3)) for b, start in [("C4", 0.0), ("G4", 0.48), ("F4", 1.08), ("G4", 1.56), ("C4", 2.4)]]
    parts += [(2.9, chirp(560, 900, 0.35, curve=0.7)), (3.2, 0.5 * bell(note("C7"), 0.9, 2.0, 1.0))]
    s["greeting"] = at(4.17, *parts)
    return s


def write(path, x, level_db):
    x = x - x.mean()
    rms = np.sqrt((x ** 2).mean()) + 1e-12
    x = x * (10 ** (level_db / 20) / rms)
    peak = np.abs(x).max()
    if peak > 0.89:  # never clip (−1 dBFS)
        x = x * 0.89 / peak
    fade = min(len(x), int(SR * 0.004))
    x[-fade:] *= np.linspace(1, 0, fade)
    # A hint of width: the right channel a few samples late.
    right = np.concatenate([np.zeros(12), x[:-12]])
    pcm = (np.stack([x, right], axis=1) * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def main():
    sounds = make()
    assert set(sounds) == set(LEVEL), set(LEVEL) ^ set(sounds)
    mac = os.path.join(ROOT, "NotchBuddy", "Resources", "sounds")
    android = os.path.join(ROOT, "android", "app", "src", "main", "res", "raw")
    for name, x in sorted(sounds.items()):
        write(os.path.join(mac, f"{name}.wav"), x.copy(), LEVEL[name])
        if name in ANDROID:
            write(os.path.join(android, f"{name}.wav"), x.copy(), LEVEL[name])
    print(f"{len(sounds)} sounds written ({len(ANDROID)} for Android).")


if __name__ == "__main__":
    main()
