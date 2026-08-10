#!/bin/bash
# Regenerates TestAudio/ — the recorded utterances the L3 replay tests
# (TESTING.md §L3) feed through the real pipeline. Uses macOS `say` so the
# set is reproducible on any Mac; all files are 16kHz 16-bit mono WAV, the
# exact format the app's mic tap produces.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p TestAudio

FMT=(--file-format=WAVE --data-format=LEI16@16000)

EN_VOICE="Samantha"   # en_US
DE_VOICE="Anna"       # de_DE
ES_VOICE="Paulina"    # es_MX

say -v "$EN_VOICE" "${FMT[@]}" -o TestAudio/en_short.wav \
  "Hello Heiko, how are you?"

say -v "$DE_VOICE" "${FMT[@]}" -o TestAudio/de_short.wav \
  "Mir geht es gut, danke."

say -v "$ES_VOICE" "${FMT[@]}" -o TestAudio/es_short.wav \
  "¿Dónde está la estación de tren, por favor?"

# The #77-review entity list (#83): every content word survives translation
# into German except "and", so a token-overlap echo rule reads the genuine
# translation as an echo. Names, brands, numbers — the app's load-bearing
# content at a till — all have this shape.
say -v "$EN_VOICE" "${FMT[@]}" -o TestAudio/en_entities.wav \
  "Apple, Google, Netflix and Amazon."

# 60 words — the R5 truncation test.
say -v "$EN_VOICE" "${FMT[@]}" -o TestAudio/en_long.wav \
  "Yesterday afternoon my wife and I walked through the old market square, \
bought fresh bread, some cheese, and a small bag of apples, then sat by the \
fountain watching the children play, talked about our summer plans, and \
decided that next weekend we should finally invite the whole family over \
for a long dinner in the garden together."

# A LONGER German reply for the after-Spanish composite: after Spanish
# context the model needs several seconds of German before its detection
# flips (verified live — the short reply above stays misdetected as Spanish
# for its entire duration, which no client-side logic can fix).
say -v "$DE_VOICE" "${FMT[@]}" -o TestAudio/de_reply_long.wav \
  "Mir geht es sehr gut, vielen Dank für die Nachfrage. Und wie geht es \
Ihnen heute bei diesem schönen Wetter?"

# The two halves of one utterance with a breath pause between them (#78):
# a natural mid-order pause, shorter than the 1.4s transcript-idle
# threshold in audio terms but longer once transcript lag is added — the
# shape that made the app talk over the speaker on device.
say -v "$DE_VOICE" "${FMT[@]}" -o TestAudio/de_pause_a.wav \
  "Ich hätte gerne einmal das große Schnitzel"
say -v "$DE_VOICE" "${FMT[@]}" -o TestAudio/de_pause_b.wav \
  "und dazu bitte noch eine große Apfelschorle."

# Composite files: utterance, a long pause (so the turn can finalize while
# the translation streams back), then a second utterance in German. These
# test the direction memory — German must come back in the language heard
# before it.
python3 - <<'PY'
import wave

def read(path):
    with wave.open(path, "rb") as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, 16000), path
        return w.readframes(w.getnframes())

def write(path, *chunks):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        for c in chunks:
            w.writeframes(c)

def silence(seconds):
    return b"\x00\x00" * int(16000 * seconds)

import random
random.seed(42)  # reproducible "background noise"
def noise(seconds, amplitude=300):
    out = bytearray()
    for _ in range(int(16000 * seconds)):
        s = random.randint(-amplitude, amplitude)
        out += s.to_bytes(2, "little", signed=True)
    return bytes(out)

en, de, es = read("TestAudio/en_short.wav"), read("TestAudio/de_short.wav"), read("TestAudio/es_short.wav")
de_long = read("TestAudio/de_reply_long.wav")
gap = silence(6.0)

write("TestAudio/de_after_en.wav", en, gap, de, silence(1.0))
write("TestAudio/de_after_es.wav", es, gap, de_long, silence(1.0))
# One utterance, breath pause inside (#78). 1.8s: long enough that the
# TRANSCRIPT gap clears the 1.4s release threshold (transcript events lag
# the audio ~1.6-1.8s, measured in this replay, so a shorter pause never
# even arms the old failure), short enough that the resumed speech is
# already flowing when the release attempt fires. The model keeps it one
# utterance at 1.8s.
pa, pb = read("TestAudio/de_pause_a.wav"), read("TestAudio/de_pause_b.wav")
write("TestAudio/de_pause.wav", pa, silence(1.8), pb, silence(1.0))
write("TestAudio/silence.wav", silence(5.0))
write("TestAudio/noise.wav", noise(5.0))
print("composite + silence/noise files written")
PY

ls -la TestAudio/
