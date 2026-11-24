#!/usr/bin/env python3
"""One-time generator for audio/*.ogg: creepy church-organ tunes.

Everything is synthesised here (no samples, no soundfont):
  - each pipe is a stack of sine partials, like organ stops (16', 8', 4', 2 2/3', 2' ...),
  - every pipe is a few cents out of tune, so chords beat slowly like an old organ,
  - a tremulant wobbles the volume, a short noise "chiff" marks each attack,
  - a long synthetic church reverb (decaying noise impulse) sits on top.
Loops are rendered circularly: the reverb tail of the last bar wraps onto the first,
so the file loops without a click or gap.

Usage: python3 scripts/make-music.py   (needs numpy and ffmpeg with libvorbis)
Then commit audio/. CI never runs this.
"""

import os
import subprocess
import sys

import numpy as np

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "audio")
rng = np.random.default_rng(1337)  # fixed seed: reruns give the same files


def midi_hz(n):
    return 440.0 * 2.0 ** ((n - 69) / 12.0)


# Organ registrations: (frequency ratio to the note, level).
PRINCIPAL = [(0.5, 0.45), (1, 1.0), (2, 0.55), (3, 0.25), (4, 0.3), (6, 0.12), (8, 0.1)]
FLUTE = [(1, 1.0), (2, 0.35), (3, 0.08), (4, 0.06)]
DEEP_PEDAL = [(0.25, 0.5), (0.5, 1.0), (1, 0.6), (2, 0.2), (3, 0.08)]
REED = [(1, 1.0), (2, 0.5), (3, 0.6), (4, 0.3), (5, 0.35), (6, 0.15), (7, 0.18), (9, 0.08)]


def pipe(note, dur, stops, tremolo=0.0, cents=6.0, attack=0.06, release=0.35, chiff=0.05):
    """One held organ note, `dur` seconds plus release."""
    n = int((dur + release) * SR)
    t = np.arange(n) / SR
    f0 = midi_hz(note)
    out = np.zeros(n)
    for ratio, level in stops:
        f = f0 * ratio
        if f > 16000:
            continue
        for _ in range(2):  # two slightly mistuned pipes per rank
            detune = 2.0 ** (rng.uniform(-cents, cents) / 1200.0)
            phase = rng.uniform(0, 2 * np.pi)
            out += level * np.sin(2 * np.pi * f * detune * t + phase)
    env = np.ones(n)
    a = int(attack * SR)
    env[:a] = np.linspace(0, 1, a) ** 2
    r0 = int(dur * SR)
    env[r0:] = np.exp(-np.arange(n - r0) / (0.25 * release * SR))
    if tremolo:
        env *= 1.0 - tremolo * (0.5 + 0.5 * np.sin(2 * np.pi * 5.3 * t))
    out *= env
    if chiff:  # breathy onset of the pipe
        k = int(0.04 * SR)
        noise = np.convolve(rng.standard_normal(k), np.ones(8) / 8, mode="same")
        out[:k] += chiff * noise * np.exp(-np.arange(k) / (0.01 * SR))
    return out / max(1, len(stops))


def church_ir(seconds=4.5, rt60=3.8):
    n = int(seconds * SR)
    t = np.arange(n) / SR
    ir = rng.standard_normal((2, n)) * np.exp(-6.9 * t / rt60)
    # darker tail: stone absorbs highs over time (one-pole lowpass, cutoff falls)
    for ch in range(2):
        y = 0.0
        for i in range(n):
            a = 0.35 + 0.6 * min(1.0, t[i] / rt60)
            y = a * y + (1 - a) * ir[ch, i]
            ir[ch, i] = y
    ir[:, : int(0.02 * SR)] = 0  # pre-delay
    return ir / np.sqrt((ir**2).sum(axis=1, keepdims=True))


IR = church_ir()


def render(events, bpm, beats, loop, wet=0.45):
    """events: (start_beat, length_beats, notes, stops, kwargs). Returns stereo float array."""
    spb = 60.0 / bpm
    length = int(beats * spb * SR)
    tail = int(5 * SR)
    dry = np.zeros((2, length + tail))
    for start, dur, notes, stops, kw in events:
        pan = kw.pop("pan", 0.0)
        gain = kw.pop("gain", 1.0)
        for note in notes:
            s = pipe(note, dur * spb, stops, **kw)
            i = int(start * spb * SR)
            p = np.clip(pan + rng.uniform(-0.15, 0.15), -1, 1)  # pipes spread across the case
            dry[0, i : i + len(s)] += gain * s * (1 - p) / 2
            dry[1, i : i + len(s)] += gain * s * (1 + p) / 2
    if loop:  # wrap the tail onto the start, then reverb circularly
        dry[:, :tail] += dry[:, length:]
        dry = dry[:, :length]
        size = length
    else:
        size = dry.shape[1] + IR.shape[1]
    wetsig = np.stack(
        [np.fft.irfft(np.fft.rfft(dry[c], size) * np.fft.rfft(IR[c], size), size) for c in range(2)]
    )
    if not loop:
        dry = np.pad(dry, ((0, 0), (0, size - dry.shape[1])))
    mix = (1 - wet) * dry + wet * wetsig * 0.6
    if not loop:  # trim trailing silence
        mix = mix[:, : int((beats * spb + 4.0) * SR)]
        fade = int(1.0 * SR)
        mix[:, -fade:] *= np.linspace(1, 0, fade) ** 2
    return mix / np.abs(mix).max() * 0.89


def chords(progression, stops, beats_per=4, **kw):
    return [(i * beats_per, beats_per, c, stops, dict(kw)) for i, c in enumerate(progression)]


def line(notes, stops, **kw):
    """notes: list of (midi or None, beats)."""
    ev, b = [], 0.0
    for n, d in notes:
        if n is not None:
            ev.append((b, d * 0.95, [n], stops, dict(kw)))
        b += d
    return ev


def crypt_hymn():
    """D minor, slow, Neapolitan Eb and a diminished chord before the loop."""
    prog = [
        [57, 62, 65],  # Dm
        [53, 58, 62],  # Bb
        [55, 58, 62],  # Gm
        [52, 55, 61],  # A7
        [57, 62, 65],  # Dm
        [55, 58, 63],  # Eb (Neapolitan)
        [52, 55, 58],  # C#dim7 (upper)
        [52, 57, 61],  # A
    ]
    pedal = [[38], [34], [31], [33], [38], [39], [37], [33]]
    mel = [
        (69, 2), (74, 1), (77, 1),
        (77, 2), (74, 1), (70, 1),
        (70, 1), (69, 1), (67, 2),
        (69, 1), (73, 1), (76, 1), (79, 1),
        (77, 2), (76, 1), (74, 1),
        (75, 2), (74, 1), (70, 1),
        (73, 1), (76, 1), (79, 1), (82, 1),
        (81, 2), (76, 1), (73, 1),
    ]
    ev = chords(prog, PRINCIPAL, gain=0.8, tremolo=0.05)
    ev += chords(pedal, DEEP_PEDAL, gain=1.1, attack=0.15, chiff=0.0)
    ev += line(mel, REED, gain=0.6, pan=0.3, attack=0.03)
    return render(ev, bpm=58, beats=32, loop=True)


def dirge():
    """A minor lament bass sliding down by semitones, soft flutes, heavy tremulant."""
    prog = [
        [57, 60, 64],  # Am
        [56, 59, 64],  # E/G#
        [55, 60, 64],  # C/G
        [54, 57, 62],  # D/F#
        [53, 57, 62],  # Dm/F
        [52, 57, 60],  # Am/E
        [53, 59, 63],  # F7(#11): the tritone F-B
        [56, 62, 64],  # E7
    ]
    bass = [[33], [32], [31], [30], [29], [28], [29], [28]]
    mel = [
        (76, 4),
        (76, 2), (71, 2),
        (72, 3), (71, 1),
        (69, 4),
        (77, 2), (76, 1), (74, 1),
        (72, 2), (71, 1), (69, 1),
        (71, 2), (75, 2),
        (68, 3), (None, 1),
    ]
    ev = chords(prog, FLUTE, gain=0.9, tremolo=0.22, chiff=0.03)
    ev += chords(bass, DEEP_PEDAL, gain=1.2, attack=0.3, chiff=0.0, tremolo=0.1)
    ev += line(mel, FLUTE, gain=0.55, pan=-0.3, tremolo=0.3, cents=9)
    return render(ev, bpm=48, beats=32, loop=True, wet=0.55)


def sting():
    """One-shot: a cluster swelling in, for a scare. Not a loop."""
    ev = [
        (0, 3, [26, 38], DEEP_PEDAL, dict(gain=1.3, attack=1.2, chiff=0.0)),
        (0, 3, [50, 53, 56, 59], PRINCIPAL, dict(gain=0.9, attack=0.8)),  # D F Ab B: dim7
        (1.5, 1.5, [63, 68], REED, dict(gain=0.7, attack=0.05, cents=14)),  # Eb Ab: the clash
    ]
    return render(ev, bpm=60, beats=3, loop=False, wet=0.6)


def write_ogg(name, stereo):
    os.makedirs(OUT, exist_ok=True)
    pcm = (stereo.T * 32767).astype("<i2").tobytes()
    path = os.path.join(OUT, name + ".ogg")
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-f", "s16le", "-ar", str(SR), "-ac", "2", "-i", "-",
         "-c:a", "libvorbis", "-q:a", "3", path],
        input=pcm, check=True,
    )
    print(f"{path}: {stereo.shape[1] / SR:.1f} s, {os.path.getsize(path) // 1024} KiB", file=sys.stderr)


if __name__ == "__main__":
    write_ogg("crypt_hymn", crypt_hymn())
    write_ogg("dirge", dirge())
    write_ogg("sting", sting())
