# DJ keys for Mixxx

`generate.py` writes two files from one table:

- Mixxx's mapping: `~/Library/Containers/org.mixxx.mixxx/Data/Library/Application Support/Mixxx/Custom.kbd.cfg`. The previous file is kept as `Custom.kbd.cfg.before-harmonizer`.
- A Karabiner-Elements rule: `~/.config/karabiner/assets/complex_modifications/harmonizer-mixxx-dj.json`.

Karabiner turns the gestures below into hidden shortcuts (F13/F16–F19 plus modifiers; Mixxx never receives F20) that the Mixxx mapping binds to controls. It does this only while Mixxx is the front app.

| Keys | Action |
|---|---|
| **3 E D C** / **4 R F V** (left / right deck) | High / Mid / Low EQ, Filter (quick effect) |
| **1 Q A Z** / **2 W S X** (left / right deck) | Stems: Drums / Bass / Melody / Vocals (Mixxx 2.6+, STEM files) |
| Hold one of those + **↑ / ↓** | Raise / lower it smoothly |
| Double-tap an EQ or filter key | Reset it to centre |
| Double-tap a stem key | Solo it (the other three to 0). Double-tap it again: all four back to normal |
| **T / Y** | Sync, left / right |
| **⇧T / ⇧Y** | Headphone cue (PFL) |
| **G / H** | Play |
| **B / N** | Cue (⇧ = set cue) |
| **5 6 7 8** / **9 0 - =** | Hotcues 1–4 (⇧ = clear) |
| **U I** / **O P** | Beat jump back / forward |
| **J K** / **L ;** | Loop / reloop |
| **[ ]** / **, .** | Loop ½ / ×2 |
| **← → \\** | Crossfader left / right / centre |
| **⇧← / ⇧→** | Load the selected track into the left / right deck |

Rerun `python3 generate.py` after editing it. Restart Mixxx to load the mapping.
