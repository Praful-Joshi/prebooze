# Code signing

`scripts/build-app.sh` signs every build of Pregame.app with the same self-signed certificate, called **Pregame Self-Signed**, and with the hardened runtime. macOS identifies an app by its signature's *designated requirement*. With this certificate that requirement is the bundle ID plus the certificate's hash, so it stays the same on every rebuild. Folder access you grant once (Downloads, Music, an external drive) therefore carries over to the next build. With ad hoc signing the requirement was the build's own hash, which changes on every build, so macOS asked again each time.

The build stops with an error if the certificate isn't in your keychain. Set `PREGAME_SIGNING_IDENTITY` to sign with a certificate that has a different name.

## One-time setup

```sh
scripts/make-signing-identity.sh ~/Documents/pregame-signing.p12
```

This does three things:

- creates a code-signing certificate valid for 20 years
- imports it into your login keychain, so that `codesign` may use it
- writes a passphrase-protected backup of the certificate and its private key to the path you give

Then:

1. **Move the backup** and its passphrase to a password manager or other safe place. **Never commit the backup.**
2. On the first build, macOS may ask whether `codesign` can use the key. Choose **Always Allow**.

The certificate isn't trusted by macOS, and it doesn't need to be. `codesign` signs with it as long as it's in your keychain, and the designated requirement compares hashes, not trust.

Don't create a second certificate. A new certificate is a new designated requirement, so macOS treats the next build as a different app and forgets its folder access. The script refuses to run while the certificate already exists.

## On a new Mac, or after losing the keychain

Restore the backup instead of creating a new certificate. macOS asks for the backup's passphrase:

```sh
security import ~/Documents/pregame-signing.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
```

Release builds signed in CI ([#11](https://github.com/Praful-Joshi/pregame/issues/11)) must import this same backup as a secret. A different certificate would make every update a different app to macOS, and Mix Hosts would lose the folder access they granted.

## Checking it

`build-app.sh` prints the designated requirement after signing:

```
designated => identifier "com.prafuljoshi.pregame" and certificate leaf = H"…"
```

Two builds should print the same line. To check that a new build satisfies an earlier build's requirement, which is what macOS checks before reusing granted access, paste that build's requirement in:

```sh
codesign --verify --strict -R='identifier "com.prafuljoshi.pregame" and certificate leaf = H"…"' build/Pregame.app
```

To see it for real, grant a folder macOS protects (Downloads, Desktop, Documents or an external drive), rebuild, and reopen a Mix from it: no prompt should appear. The first build after switching from ad hoc signing asks once more, because its identity is new.

CI checks the requirement with a throwaway certificate on every push (the `signed-app` job in `.github/workflows/ci.yml`).

## Hardened runtime and bundled libraries

The app, `libtag.2.dylib` and `libonnxruntime.1.dylib` are all signed with the hardened runtime. The hardened runtime's library validation only loads libraries signed by the app's own team, and a self-signed certificate has no team. So the app carries one entitlement, `com.apple.security.cs.disable-library-validation` (`scripts/Pregame.entitlements`), which lets it load its bundled libraries. The App Sandbox entitlements will join it ([ADR-0003](adr/0003-app-sandbox-from-v1.md)).
