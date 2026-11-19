#!/usr/bin/env python3
"""Generate the Mixxx keyboard mapping (Custom.kbd.cfg) and the Karabiner-Elements
rules that drive it, from one table, so they can't drift apart.

Gestures (only while Mixxx is the front app):
  3 E D C / 4 R F V  left / right deck  High, Mid, Low EQ, Filter (quick effect)
  1 Q A Z / 2 W S X   left / right deck  stems: Drums, Bass, Melody, Vocals (Mixxx 2.6+, STEM files)
  hold one of those + ↑ / ↓   raise / lower it smoothly (repeats while held)
  double-tap an EQ/filter key reset it to default
  double-tap a stem key       solo it (other three stems to 0); double-tap it again → all four back to default
Karabiner turns each gesture into an unused hidden shortcut (F13/F16–F19 + modifiers)
that Custom.kbd.cfg maps to the Mixxx control.

  python3 generate.py            # writes both files to their places
"""
import itertools, json, os, sys

HOME = os.path.expanduser("~")
KBD = f"{HOME}/Library/Containers/org.mixxx.mixxx/Data/Library/Application Support/Mixxx/Custom.kbd.cfg"
KARABINER = f"{HOME}/.config/karabiner/assets/complex_modifications/harmonizer-mixxx-dj.json"
APP = [{"type": "frontmost_application_if", "bundle_identifiers": ["^org\\.mixxx\\.mixxx$"]}]
DOUBLE_TAP_MS = 250

# Hidden shortcuts: (Karabiner key, Karabiner modifiers, Mixxx key sequence).
KEYS = ["f13", "f16", "f17", "f18", "f19"]    # F14/F15 = brightness on macOS; Mixxx never sees F20
MODS = [("left_control", "Meta"), ("left_option", "Alt"), ("left_shift", "Shift"), ("left_command", "Ctrl")]
def hidden_shortcuts():
    for n in (1, 2, 3):
        for combo in itertools.combinations(MODS, n):
            if combo == (("left_command", "Ctrl"),):
                continue
            for k in KEYS:
                yield k, [m for m, _ in combo], "+".join(q for _, q in combo) + "+" + k.upper()
pool = hidden_shortcuts()
kbd_lines = {}          # group -> [lines]
def hotkey(group, control):
    k, mods, seq = next(pool)
    kbd_lines.setdefault(group, []).append(f"{control} {seq}")
    return {"key_code": k, "modifiers": mods}

eq_group = lambda d: f"[EqualizerRack1_[Channel{d}]_Effect1]"
filter_group = lambda d: f"[QuickEffectRack1_[Channel{d}]]"
stem_group = lambda d, s: f"[Channel{d}_Stem{s}]"

# Targets: (physical key, kind, deck, index)
targets = []
for d, keys in ((1, "3edc"), (2, "4rfv")):
    for key, param in zip(keys, (3, 2, 1, "filter")):  # parameter3 = High, 2 = Mid, 1 = Low
        targets.append((key, "eq", d, param))
for d, keys in ((1, ["1", "q", "a", "z"]), (2, ["2", "w", "s", "x"])):
    for s, key in enumerate(keys, 1):
        targets.append((key, "stem", d, s))

# Hotkeys per target.
for i, t in enumerate(targets):
    key, kind, d, n = t
    if kind == "eq":
        g, c = (filter_group(d), "super1") if n == "filter" else (eq_group(d), f"parameter{n}")
        t_hot = {"up": hotkey(g, c + "_up_small"), "down": hotkey(g, c + "_down_small"), "reset": hotkey(g, c + "_set_default")}
    else:
        g = stem_group(d, n)
        t_hot = {"up": hotkey(g, "volume_up_small"), "down": hotkey(g, "volume_down_small"),
                 "default": hotkey(g, "volume_set_default"), "zero": hotkey(g, "volume_set_zero")}
    targets[i] = (key, kind, d, n, t_hot)

def var(name, value): return {"set_variable": {"name": name, "value": value}}
def cond(name, value): return {"type": "variable_if", "name": name, "value": value}

manipulators = []
for tid, (key, kind, d, n, hot) in enumerate(targets, 1):
    frm = {"key_code": key, "modifiers": {"optional": ["caps_lock"]}}
    hold = {"to_after_key_up": [var("mixxx_target", 0)]}
    tap = f"mixxx_tap_{key}"
    if kind == "eq":
        manipulators.append({"type": "basic", "from": frm, "conditions": APP + [cond(tap, 1)],
                             "to": [var(tap, 0), var("mixxx_target", tid), hot["reset"]], **hold})
    else:
        stems = [t for t in targets if t[1] == "stem" and t[2] == d]
        solo = f"mixxx_solo_{d}"
        restore = [s[4]["default"] for s in stems]
        solo_to = [hot["default"]] + [s[4]["zero"] for s in stems if s[3] != n]
        manipulators.append({"type": "basic", "from": frm, "conditions": APP + [cond(tap, 1), cond(solo, n)],
                             "to": [var(tap, 0), var(solo, 0), var("mixxx_target", tid)] + restore, **hold})
        manipulators.append({"type": "basic", "from": frm, "conditions": APP + [cond(tap, 1)],
                             "to": [var(tap, 0), var(solo, n), var("mixxx_target", tid)] + solo_to, **hold})
    manipulators.append({"type": "basic", "from": frm, "conditions": APP,
                         "to": [var(tap, 1), var("mixxx_target", tid)], **hold,
                         "to_delayed_action": {"to_if_invoked": [var(tap, 0)], "to_if_canceled": [var(tap, 0)]},
                         "parameters": {"basic.to_delayed_action_delay_milliseconds": DOUBLE_TAP_MS}})
    for arrow, which in (("up_arrow", "up"), ("down_arrow", "down")):
        manipulators.append({"type": "basic", "from": {"key_code": arrow, "modifiers": {"optional": ["any"]}},
                             "conditions": APP + [cond("mixxx_target", tid)], "to": [hot[which]]})

karabiner = {"title": "Pregame: DJ keys for Mixxx",
             "rules": [{"description": "Mixxx: EQ + filter (3EDC/4RFV) and stems (1QAZ/2WSX): hold + ↑/↓ to adjust, double-tap to reset / solo",
                        "manipulators": manipulators}]}

# Plain keys: the rest of the layout (Karabiner leaves these alone).
plain = {
    "[Master]": ["crossfader_down Left", "crossfader_up Right", "crossfader_set_default \\"],
    "[Channel1]": ["play g", "cue_set Shift+G", "cue_default b", "cue_gotoandstop Shift+B",
                   "sync_enabled t", "pfl Shift+T",
                   "hotcue_1_activate 5", "hotcue_2_activate 6", "hotcue_3_activate 7", "hotcue_4_activate 8",
                   "hotcue_1_clear Shift+%", "hotcue_2_clear Shift+^", "hotcue_3_clear Shift+&", "hotcue_4_clear Shift+*",
                   "beatjump_backward u", "beatjump_forward i", "beatloop_activate j", "reloop_toggle k",
                   "loop_halve [", "loop_double ]",
                   "rate_perm_down F1", "rate_perm_up F2", "rate_temp_down F3", "rate_temp_up F4",
                   "LoadSelectedTrack Shift+Left", "eject Alt+Shift+Left", "bpm_tap Shift+!"],
    "[Channel2]": ["play h", "cue_set Shift+H", "cue_default n", "cue_gotoandstop Shift+N",
                   "sync_enabled y", "pfl Shift+Y",
                   "hotcue_1_activate 9", "hotcue_2_activate 0", "hotcue_3_activate -", "hotcue_4_activate =",
                   "hotcue_1_clear Shift+(", "hotcue_2_clear Shift+)", "hotcue_3_clear Shift+_", "hotcue_4_clear Shift++",
                   "beatjump_backward o", "beatjump_forward p", "beatloop_activate l", "reloop_toggle ;",
                   "loop_halve ,", "loop_double .",
                   "rate_perm_down F5", "rate_perm_up F6", "rate_temp_down F7", "rate_temp_up F8",
                   "LoadSelectedTrack Shift+Right", "eject Alt+Shift+Right", "bpm_tap Shift+@"],
    "[AutoDJ]": ["shuffle_playlist Shift+F9", "skip_next Shift+F10", "fade_now Shift+F11", "enabled Shift+F12"],
    "[Microphone]": ["talkover `"],
}
shortcuts = """[KeyboardShortcuts]
FileMenu_LoadDeck1 Ctrl+o
FileMenu_LoadDeck2 Ctrl+Shift+O
FileMenu_Quit Ctrl+q
LibraryMenu_NewPlaylist Ctrl+n
LibraryMenu_NewCrate Ctrl+Shift+N
ViewMenu_ShowSkinSettings Ctrl+1
ViewMenu_ShowMicrophone Ctrl+2
ViewMenu_ShowVinylControl Ctrl+3
ViewMenu_ShowPreviewDeck Ctrl+4
ViewMenu_ShowEffects Ctrl+5
ViewMenu_ShowCoverArt Ctrl+6
ViewMenu_MaximizeLibrary Space
OptionsMenu_RecordMix Ctrl+r
OptionsMenu_EnableShortcuts Ctrl+`
"""

out = ["// Pregame DJ keys for Mixxx (generated by pregame/scripts/mixxx-keys/generate.py).",
       "// EQ and stem gestures come from Karabiner-Elements as hidden F13/F16-F19 shortcuts below.", ""]
for g, lines in plain.items():
    out += [g] + lines + [""]
for g, lines in kbd_lines.items():
    out += [g] + lines + [""]
out.append(shortcuts)

if __name__ == "__main__":
    dry = "--print" in sys.argv
    if dry:
        print("\n".join(out)); print(json.dumps(karabiner, indent=1)[:2000]); sys.exit()
    os.makedirs(os.path.dirname(KARABINER), exist_ok=True)
    json.dump(karabiner, open(KARABINER, "w"), indent=2)
    if os.path.exists(KBD) and not os.path.exists(KBD + ".before-harmonizer"):
        os.rename(KBD, KBD + ".before-harmonizer")
    open(KBD, "w").write("\n".join(out))
    print("wrote", KBD); print("wrote", KARABINER)
    print(f"{len(manipulators)} Karabiner manipulators, {sum(len(v) for v in kbd_lines.values())} hidden shortcuts")
