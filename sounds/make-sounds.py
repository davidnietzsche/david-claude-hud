#!/usr/bin/env python3
"""Generate the HUD's two alert sounds.

Committed as WAVs so the repo is self-contained and every install sounds the
same, but regenerating them is a one-liner if you want a different character.
Pure stdlib — no samples downloaded, nothing to license.

The two need to be told apart without looking:
  done      a soft rising two-note chime — something good happened, no rush
  needs-you three insistent pulses on a flat pitch — you are the blocker
"""

import array
import math
import os
import wave

RATE = 44100


def tone(freq, dur, amp=0.28, attack=0.012, release=None, vibrato=0.0):
    """One enveloped sine. The attack/release ramps matter: a raw sine that
    starts or stops at a non-zero sample makes an audible click."""
    release = dur * 0.55 if release is None else release
    n = int(RATE * dur)
    out = []
    for i in range(n):
        t = i / RATE
        f = freq * (1 + vibrato * math.sin(2 * math.pi * 6.0 * t))
        env = 1.0
        if t < attack:
            env = t / attack
        elif t > dur - release:
            env = max(0.0, (dur - t) / release)
        # a touch of second harmonic keeps it from sounding like a test tone
        s = math.sin(2 * math.pi * f * t) + 0.18 * math.sin(4 * math.pi * f * t)
        out.append(amp * env * s / 1.18)
    return out


def silence(dur):
    return [0.0] * int(RATE * dur)


def mix(*parts):
    return [s for p in parts for s in p]


def write(path, samples):
    frames = array.array("h", (int(max(-1.0, min(1.0, s)) * 32767) for s in samples))
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(frames.tobytes())
    print(f"  {os.path.basename(path):<14} {len(samples)/RATE:.2f}s")


def main():
    here = os.path.dirname(os.path.abspath(__file__))

    # E5 -> A5, gentle and resolved.
    write(os.path.join(here, "done.wav"),
          mix(tone(659.25, 0.16, amp=0.24),
              tone(880.00, 0.34, amp=0.26)))

    # Three short knocks on A5 — same pitch each time, so it reads as a prompt
    # rather than a melody, and a little vibrato to make it insistent.
    pulse = tone(880.00, 0.11, amp=0.30, release=0.05, vibrato=0.012)
    gap = silence(0.075)
    write(os.path.join(here, "needs-you.wav"),
          mix(pulse, gap, pulse, gap, pulse))


if __name__ == "__main__":
    main()
