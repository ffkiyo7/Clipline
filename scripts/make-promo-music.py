# Usage: python3 scripts/make-promo-music.py out.wav  (needs numpy and scipy), then
#   ffmpeg -i out.wav -af loudnorm=I=-16:TP=-1.5:LRA=9 bgm.wav
# Original 30 s score for the Clipline promo. 120 BPM, so every cut
# (3.5, 8, 13.5, 19, 24, 27.5 s) lands on a beat.
import numpy as np
from scipy.signal import fftconvolve, butter, sosfilt
import wave, sys

SR = 48000
DUR = 30.0
BEAT = 0.5
N = int(SR * (DUR + 0.0))
L = np.zeros(N); R = np.zeros(N)
rng = np.random.default_rng(7)

def midi(n): return 440.0 * 2 ** ((n - 69) / 12)

def place(sig, t, pan=0.0, gain=1.0):
    i = int(t * SR)
    if i >= N: return
    sig = sig[: N - i] * gain
    l = np.cos((pan + 1) * np.pi / 4); r = np.sin((pan + 1) * np.pi / 4)
    L[i:i + len(sig)] += sig * l * 1.414
    R[i:i + len(sig)] += sig * r * 1.414

def env(n, a, d):
    t = np.arange(n) / SR
    return np.minimum(1, t / a) * np.exp(-t / d)

def mallet(note, dur=1.6, vel=1.0):
    f = midi(note); n = int(dur * SR); t = np.arange(n) / SR
    s = (np.sin(2 * np.pi * f * t) * np.exp(-t / 0.55)
         + 0.35 * np.sin(2 * np.pi * f * 4.0 * t) * np.exp(-t / 0.07)
         + 0.12 * np.sin(2 * np.pi * f * 9.2 * t) * np.exp(-t / 0.025))
    return s * np.minimum(1, t / 0.002) * vel

def bell(note, dur=3.0, vel=1.0):
    f = midi(note); n = int(dur * SR); t = np.arange(n) / SR
    s = (np.sin(2 * np.pi * f * t) * np.exp(-t / 1.2)
         + 0.4 * np.sin(2 * np.pi * f * 2.0 * t) * np.exp(-t / 0.6)
         + 0.2 * np.sin(2 * np.pi * f * 3.01 * t) * np.exp(-t / 0.3))
    return s * np.minimum(1, t / 0.003) * vel

def pad(notes, dur, vel=1.0):
    n = int(dur * SR); t = np.arange(n) / SR
    s = np.zeros(n)
    for note in notes:
        f = midi(note)
        for det in (-0.07, 0.0, 0.07):
            ff = f * 2 ** (det / 12)
            ph = rng.uniform(0, 2 * np.pi)
            s += np.sin(2 * np.pi * ff * t + ph) + 0.25 * np.sin(4 * np.pi * ff * t + ph) + 0.08 * np.sin(6 * np.pi * ff * t + ph)
    a = np.minimum(1, t / 0.6) * np.minimum(1, (dur - t) / 0.5)
    return s * np.clip(a, 0, 1) * vel / (len(notes) * 3)

def bass(note, dur, vel=1.0):
    f = midi(note); n = int(dur * SR); t = np.arange(n) / SR
    s = np.tanh(1.6 * (np.sin(2 * np.pi * f * t) + 0.2 * np.sin(4 * np.pi * f * t)))
    return s * np.minimum(1, t / 0.005) * np.exp(-t / 0.5) * np.minimum(1, (dur - t) / 0.03).clip(0) * vel

def kick(vel=1.0):
    n = int(0.35 * SR); t = np.arange(n) / SR
    f = 45 + 90 * np.exp(-t / 0.03)
    ph = 2 * np.pi * np.cumsum(f) / SR
    return np.sin(ph) * np.exp(-t / 0.12) * vel

def noise_hit(dur, decay, lo, hi, vel=1.0):
    n = int(dur * SR); t = np.arange(n) / SR
    sos = butter(2, [lo, hi], btype='band', fs=SR, output='sos')
    return sosfilt(sos, rng.standard_normal(n)) * np.exp(-t / decay) * vel

def swell(dur, vel=1.0):
    n = int(dur * SR); t = np.arange(n) / SR
    sos = butter(2, [2500, 9000], btype='band', fs=SR, output='sos')
    return sosfilt(sos, rng.standard_normal(n)) * (t / dur) ** 2.5 * vel

# D  A  Bm  G, two seconds (one bar) each.
chords = [(62, 66, 69), (61, 64, 69), (59, 62, 66), (59, 62, 67)]
roots = [38, 45, 35, 43]
arp_shapes = [[74, 78, 81, 86, 81, 78, 81, 78], [73, 76, 81, 85, 81, 76, 81, 76],
              [71, 74, 78, 83, 78, 74, 78, 74], [71, 74, 79, 83, 79, 74, 79, 74]]
melody = {  # bar index -> [(beat offset, note, length)]
    4: [(0, 90, 1), (1.5, 88, .5), (2, 86, 1.5)], 5: [(0, 88, 1), (1.5, 85, .5), (2, 81, 1.5)],
    6: [(0, 86, 1), (1.5, 85, .5), (2, 83, 1), (3, 81, 1)], 7: [(0, 83, 2), (2.5, 86, .5), (3, 88, 1)],
    8: [(0, 90, 1), (1.5, 93, .5), (2, 90, 1.5)], 9: [(0, 88, 1), (1.5, 85, .5), (2, 88, 1.5)],
    10: [(0, 86, 1), (1, 85, .5), (1.5, 83, .5), (2, 81, 2)], 11: [(0, 83, 1.5), (2, 86, 1), (3, 88, .5)],
}
bars = 15
for b in range(bars):
    t0 = b * 4 * BEAT
    c = b % 4
    ending = t0 >= 27.5 - 1e-6
    intro = b < 2
    if b < 14:
        place(pad(chords[c], 2.15, 0.9 if not intro else 0.7), t0, gain=0.22)
    # arpeggio
    if b < 13 or (b == 13 and True):
        for k, note in enumerate(arp_shapes[c]):
            t = t0 + k * BEAT / 2
            if t >= 27.5: break
            if intro and k % 2 == 1: continue
            light = 0.55 if 24 <= t < 27.5 else 1.0
            place(mallet(note, 1.2, 0.9 if k % 4 == 0 else 0.65), t, pan=0.35 * np.sin(k), gain=0.16 * light)
    # groove from 4 s to 27.5 s
    for k in range(4):
        t = t0 + k * BEAT
        if t < 4.0 or t >= 27.5: continue
        soft = 0.6 if 24 <= t < 27.5 else 1.0
        if k in (0, 2): place(kick(), t, gain=0.55 * soft)
        if k in (1, 3): place(noise_hit(0.25, 0.06, 900, 6000), t, pan=0.1, gain=0.10 * soft)
        for s in range(2):
            place(noise_hit(0.08, 0.018, 6000, 14000), t + s * BEAT / 2 + 0.25 * BEAT, pan=-0.3, gain=0.05 * soft)
        if k == 0: place(bass(roots[c], 0.9), t, gain=0.32 * soft)
        if k == 1: place(bass(roots[c], 0.4), t + 0.5 * BEAT, gain=0.24 * soft)
        if k == 2: place(bass(roots[c] + 12 if c != 1 else roots[c], 0.9), t, gain=0.26 * soft)
    for off, note, ln in melody.get(b, []):
        t = t0 + off * BEAT
        place(bell(note - 12, 2.0, 1.0), t, pan=-0.15, gain=0.11)

# Cuts: a soft swell into each, a little chime on it.
for cut, note in [(3.5, 86), (8, 85), (13.5, 83), (19, 86), (24, 81), (27.5, 86)]:
    place(swell(0.5), cut - 0.5, gain=0.05)
    place(bell(note + 12, 1.5, 0.6), cut, pan=0.25, gain=0.07)
# The line dropping in the hero, the copy click at ~6.95 s.
place(bell(98, 1.2, 0.5), 1.2, pan=0.3, gain=0.06)
# Ending: a resolving D chord that rings out.
for note in (50, 62, 66, 69, 74, 78):
    place(bell(note, 3.2, 1.0), 27.5, pan=(note - 66) / 30, gain=0.09)
place(pad((62, 66, 69, 74), 2.5, 1.0), 27.5, gain=0.25)
place(bass(38, 2.4), 27.5, gain=0.3)

# Room: a short stereo noise tail.
def ir(seed):
    n = int(1.6 * SR); t = np.arange(n) / SR
    r = np.random.default_rng(seed).standard_normal(n) * np.exp(-t / 0.45)
    sos = butter(1, 7000, btype='low', fs=SR, output='sos')
    return sosfilt(sos, r) / np.sqrt(np.sum(r ** 2))
wetL = fftconvolve(L, ir(1))[:N]; wetR = fftconvolve(R, ir(2))[:N]
outL = L + 0.28 * wetL; outR = R + 0.28 * wetR
# Fade the last 0.6 s, glue, normalise.
fade = np.ones(N); fn = int(0.6 * SR); fade[-fn:] = np.linspace(1, 0, fn) ** 2
outL *= fade; outR *= fade
out = np.stack([outL, outR], 1)
out = np.tanh(out / np.max(np.abs(out)) * 1.2) / np.tanh(1.2) * 0.89
with wave.open(sys.argv[1], 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((out * 32767).astype('<i2').tobytes())
print("ok", out.shape, float(np.sqrt(np.mean(out ** 2))))
