#!/bin/zsh
# One-time setup: create the self-signed code-signing identity that
# scripts/build-app.sh signs every build with, and export a backup of it.
#   scripts/make-signing-identity.sh ~/Documents/pregame-signing.p12
# Asks for a passphrase for the backup (or reads PREGAME_SIGNING_PASSPHRASE).
# Imports into the login keychain, or the keychain named by PREGAME_KEYCHAIN.
# See docs/signing.md, including how to restore the identity from the backup.
set -euo pipefail

IDENTITY="${PREGAME_SIGNING_IDENTITY:-Pregame Self-Signed}"
KEYCHAIN="${PREGAME_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
BACKUP="${1:-}"

if [[ -z "$BACKUP" ]]; then
  echo "usage: $0 <backup.p12>   (keep the backup outside the repo, e.g. ~/Documents)" >&2
  exit 2
fi
if [[ -e "$BACKUP" ]]; then
  echo "error: $BACKUP already exists; choose another path" >&2
  exit 1
fi
if [[ ! -d "${BACKUP:h}" || ! -w "${BACKUP:h}" ]]; then
  echo "error: can't write the backup into ${BACKUP:h}" >&2
  exit 1
fi
# The same exact-name lookup build-app.sh signs with, in every keychain it searches.
EXISTING="$({ security find-identity -p codesigning; security find-identity -p codesigning "$KEYCHAIN"; } 2>/dev/null || true)"
if grep -qF "\"$IDENTITY\"" <<< "$EXISTING"; then
  echo "error: \"$IDENTITY\" is already in your keychains. Every build must use the same one;" >&2
  echo "a second certificate would make macOS treat the next build as a different app." >&2
  exit 1
fi

PASSPHRASE="${PREGAME_SIGNING_PASSPHRASE:-}"
if [[ -z "$PASSPHRASE" ]]; then
  read -rs "PASSPHRASE?Passphrase for the backup: "; echo
  read -rs "CONFIRM?Repeat it: "; echo
  [[ "$PASSPHRASE" == "$CONFIRM" ]] || { echo "error: passphrases differ" >&2; exit 1; }
  [[ -n "$PASSPHRASE" ]] || { echo "error: empty passphrase" >&2; exit 1; }
fi

WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# 20 years: the certificate must outlive the app, since a new one means macOS
# sees a different app. Apple's openssl (LibreSSL) writes a .p12 that the
# keychain can import; Homebrew's OpenSSL 3 defaults to a cipher it can't.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -sha256 \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
export_p12() {  # <out> <passphrase>, passed through the environment, not argv
  PREGAME_P12_PASS="$2" /usr/bin/openssl pkcs12 -export -name "$IDENTITY" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$1" -passout env:PREGAME_P12_PASS
}

# Backup first: an identity in the keychain without one can't be recovered.
(umask 077; export_p12 "$BACKUP" "$PASSPHRASE")

# `security import` takes the passphrase as an argument, so it gets a copy
# locked with a one-time passphrase; the backup's never leaves this process.
IMPORT_PASS="$(/usr/bin/openssl rand -hex 32)"
export_p12 "$WORK/import.p12" "$IMPORT_PASS"
security import "$WORK/import.p12" -k "$KEYCHAIN" -P "$IMPORT_PASS" -T /usr/bin/codesign >/dev/null

echo "Created \"$IDENTITY\" in $KEYCHAIN"
echo "Backup: $BACKUP. Store it and its passphrase somewhere safe (a password manager), never in the repo."
