# Pregame

A free macOS app that lets non-professionals turn a pile of songs into a seamless, beat-matched mix for their own use, such as a house party.

## Language

**Mix**:
An ordered list of Tracks joined by Transitions, edited and saved as one project.
_Avoid_: set, playlist, project (when meaning the musical content)

**Track**:
One audio file placed in a Mix, together with its analysis (tempo, key, beat grid, structure).
_Avoid_: song (in UI and code), clip

**Transition**:
The overlap where one Track hands over to the next, with its length, placement and effect curves.
_Avoid_: blend, crossfade (a crossfade is just one kind of Transition)

**Pool**:
Every Track added to a Mix, whether or not it currently plays in it. Tracks that don't play are shown as "Not in mix".
_Avoid_: library (the Pool belongs to one Mix), crate, excluded tracks

**Auto-pick**:
An optional starting path: the app takes a folder, adds all of it to the Pool, and chooses which Tracks play to fit a target length and Energy Shape.
_Avoid_: auto mix, smart mix, generate

**Harmonize**:
Ordering the Tracks that play for harmonic and tempo flow, and giving each Transition its default settings.
_Avoid_: sort, auto mix

**Energy Shape**:
How intense the Mix should feel over its length, chosen as a picture: Warm-up → Peak → Wind-down, Steady, Build all night, or Peaks and breathers.
_Avoid_: vibe, curve (curves belong to Transitions)

**Must-play**:
A Track in the Pool that Auto-pick has to include; it's free to choose where.
_Avoid_: pinned, locked (a lock fixes a Transition, not inclusion)

**Opener / Closer**:
The Track that Harmonize (and Auto-pick) has to put first or last.

**Match**:
A plain-word grade for how well one Transition works: Smooth, Energy up, Energy down, Key change, or Clash.
_Avoid_: compatibility, harmonic label (in UI)

**Clash**:
A Match where the two Tracks' keys or tempos fight. Every Clash offers a Fix.

**Bridge Track**:
A Track from the Pool inserted between two clashing Tracks so that both of the new Transitions are free of Clashes.

**Mix Host**:
The primary user: someone without DJ training who builds a Mix for their own listening or a party.
_Avoid_: DJ, user (when the persona matters)

**Tonight view**:
A full-screen, glanceable view for the party itself: now playing, up next, and the countdown to the next Transition.
_Avoid_: performance mode, live view

**Party mode**:
Playing a Mix live, where it can change while it plays: skips become real Transitions, and requests get slotted in by replanning the Transitions ahead.
_Avoid_: live mode, DJ mode

**Phone remote**:
A web page served by the Mac on the local network and opened from a QR code, letting the Mix Host or guests skip and request Tracks during Party mode.
_Avoid_: companion app, mobile app

## Relationships

- A **Mix** contains one or more **Tracks** in order; between each adjacent pair there is exactly one **Transition**
- A **Track** can appear in many **Mixes**; its analysis is shared across them
- A **Mix** has one **Pool**; the Tracks that play are an ordered subset of it

## Flagged ambiguities

- "playlist" was used for a Mix's Tracks before Harmonize. Resolved: it's still a **Mix**, just one that hasn't been Harmonized yet.
- "set" was used for both the Mix being built and the published recording of it. Resolved: say **Mix**. Publishing a Mix is deferred, and when it comes it goes to an external platform; we never host the audio.
