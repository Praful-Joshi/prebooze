# Ship in the App Sandbox from v1

The app ships sandboxed, with the hardened runtime, from the first public release. Its whole job is opening audio files from anywhere, and a bug in a tag, artwork or audio parser (TagLib, the decoders) shouldn't be able to reach the rest of the user's Mac.

Tracks are referenced through security-scoped bookmarks stored in the Mix file next to the path, so granted folders survive relaunches without privacy prompts. The analysis and stem caches live in the app's container.

We took this on before launch because sandboxing later would mean migrating every user's caches and projects in an update.

## Consequences

- Mix files from before the sandbox have only paths. On first open, they ask the user to re-locate each folder once.
- Every place that writes outside the container (exports, STEM files) must go through a save panel or a folder the user has granted.
