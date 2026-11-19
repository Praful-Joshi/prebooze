# Design system

Prebooze looks like a Mac app first: system materials, SF Symbols, standard controls, and the system Light/Dark setting. On top of that it has one brand accent and a domain palette. Everything lives in `Sources/HarmonizerApp/Design/`, and `DesignTokenTests` fails the build if a colour is named anywhere else in the app.

## Colour

| Role | Token | Notes |
|---|---|---|
| Brand accent | `Palette.accent` / `Ink.accent` | "Afterglow" fuchsia, `#C8217A` light / `#FF4FA8` dark. Applied once with `.tint()` at each window's root. |
| Surfaces and text | system colours | Window, sidebar material, label hierarchy, separators. |
| Canvas | `Palette.canvas` | Timeline and editor background. Not `underPageBackgroundColor`, which is mid-grey in Light mode. |
| Playhead | `Palette.playhead` | The label colour, never the accent. |

**The accent is chrome only.** Use it for primary buttons, selection, toggles that are on (including a locked Transition), focus, progress, coach marks and countdown rings (timeline and Tonight). Never use it for data, so it can't be mistaken for a Match, a lane or a section. Use it for at most one prominent button per view.

## Domain palette

Every domain colour has a Light and a Dark value; tests check the contrast in both.

| What | Colours | Rule |
|---|---|---|
| **Match** | Smooth green ✓ `checkmark` · Energy up orange `arrow.up.right` · Energy down cyan `arrow.down.right` · Key change indigo `music.note` · Clash red `exclamationmark.triangle.fill` | The word and the symbol always go with the colour. Text is at least 4.5:1 on its pill. |
| **Outgoing / incoming** | Orange solid line / blue dashed line | At least 3:1 on the canvas. |
| **Hot cues** | Yellow flag (deep gold in Light, where plain yellow vanishes), dark numeral | Kept apart from outgoing orange. The "not yellow" rule applies to the brand accent only. |
| **Sections** | Intro teal, Build gold, Drop rose, Break indigo, Outro sage | The same fill in both appearances, with dark text. |
| **Keys** | 12 hues by Camelot number; minor deeper, major lighter | A 3 pt edge on the key pill. A key shift adds `↕ +2` rather than a colour. |
| **Status** | Overridden orange, missing red, warning orange, success green | Built from the Match colours. |
| **Waveform** | Three-band mix (low red, mid green, high blue) | `Palette.waveform(low:mid:high:dark:)`, resolved once per draw because it's called per pixel column. |

Until #16 lands, the old harmonic colours map through `Palette.legacyMatch(_:)`: green → Smooth, yellow → Energy up, blue → Key change, red → Clash.

## Spacing, radius, type

- **`Space`:** 2, 4, 6, 8, 12, 16, 20, 32 (`xxs`…`xxxl`). Snap other values to the nearest step.
- **`Radius`:** `hair` 2, `small` 4, `medium` 6, `large` 10, `xl` 16, always with `style: .continuous`. Pills use `Capsule`.
- **Type:** SwiftUI text styles; monospaced digits for clocks, BPM and lengths. Fixed point sizes only inside `Canvas` drawings. SF Pro Rounded only for the Tonight countdown.

## Motion

| Token | Animation | Use |
|---|---|---|
| `hover` | easeOut 0.15 s | Hover reveals |
| `pop` | spring 0.25 / 0.7 | Pills and chips under the pointer, star toggle, a Match changing after Fix |
| `snap` | spring 0.3 / 0.8 | Presets, chip values, segmented controls |
| `settle` | spring 0.35 / 0.85 | List reorder, Pool moves, Bridge Track insert, expand/collapse |
| `glide` | smooth 0.45 s | Editor moving between Transitions, timeline scroll |
| `fade` | easeInOut 0.2 s | Content swaps, loading states |
| `breathe` | easeInOut 0.7 s, repeating | Now-playing and analysing pulses |

With Reduce Motion on, every spring and glide becomes a 0.15 s fade, and `breathe` returns nil (no loop). The timeline's scroll is an AppKit animation (`glideAppKit`); it can't fade, so with Reduce Motion it jumps.

## Screen decisions (for the issues that build them)

- **First run (#28):** an empty state with two equal cards, "Add songs" and "Auto-pick from a folder", and the whole window as a drop target. Four accent-filled coach marks (Add songs → Harmonize → Play → Export) with Next and "Skip tips"; Settings › General › "Show tips again" resets them. Files that can't be read are listed in a sheet with a plain reason, and only when there are any.
- **Consent (#12):** a sheet on first launch, before the empty state. "No thanks" and "Share selected" are plain buttons of equal weight with no default.
- **Auto-pick (#18):** a sheet with folder, length (1 h, 2 h, 3 h, All night, Custom) and four Energy Shape picture cards. It changes in place to an analysis-progress step, then closes into the filled Mix.
- **Must-play / Re-pick (#19):** a star on rows under "Not in mix". Opener and Closer badges are set from the row menu. A bar at the top of the sidebar offers Shuffle again and Re-pick once something has changed.
- **Energy (#15):** a 5-bar `cellularbars` glyph per Track, and an energy ribbon along the top of the timeline with the Energy Shape target as a dashed line.
- **Match (#16) and Fix (#17):** Match pills in the playlist, on the timeline and in the editor header. Clicking a Clash opens a popover with ranked fixes: a key shift first, then Bridge Tracks, each with a preview button.
- **Tonight (#21):** always dark. Large artwork, now playing, the countdown ring, up next, and "Jump to next Transition", noted as skipping without a blend. Artwork and titles crossfade over the Transition's real length. Esc returns to the editor.
- **Export (#22):** FLAC added, plus a "Player details" group: title, cover art and chapters.
- **Settings:** General, Audio, Updates (automatic checks, Stable/Beta channel: #10, #26), Privacy (#12), Storage. Sparkle's own windows stay stock.
- **Recovery (#27) and re-locating folders (#8, #9):** one sheet each, listing Mixes or folders rather than files.
