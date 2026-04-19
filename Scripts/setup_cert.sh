#!/usr/bin/env bash
#
# Create a local self-signed codesigning identity so repeated `make build`
# runs produce a stable code-requirement string — macOS TCC grants
# (Microphone, Accessibility) then persist across rebuilds instead of
# resetting every time the ad-hoc cdhash changes.
#
# Idempotent: if the identity already exists, the script is a no-op.
#
# Why a dedicated keychain: importing into login.keychain triggers
# macOS's partition-list GUI prompt the first time codesign tries to use
# the key ("codesign wants to use key X, Always Allow?"). That's an
# interactive hurdle for a supposedly one-shot setup script.
# A dedicated keychain with a known (empty) password lets the script
# call `security set-key-partition-list` non-interactively, so the first
# `make build` just works without any GUI click.
#
# Side effects (all user-level, no admin):
#   - Creates ~/Library/Keychains/voicetyping-dev.keychain-db
#   - Adds that keychain to the user search path (so codesign finds it)
#   - Imports a self-signed codesigning cert with CN = "VoiceTyping Dev"

set -euo pipefail

IDENTITY="${SIGNING_IDENTITY:-VoiceTyping Dev}"
KC_NAME="voicetyping-dev.keychain-db"
KC_PATH="$HOME/Library/Keychains/$KC_NAME"
# Empty password is intentional: the dedicated keychain holds only a
# self-signed cert useful for local cdhash stability. No secrets in it.
KC_PASS=""
# Throwaway password used only during the temporary PKCS12 round-trip.
# `security import` has trouble with empty-password p12 files in
# OpenSSL 3+ (MAC verification failure), so we use a non-empty sentinel.
P12_PASS="voicetyping-setup"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "✓ Codesigning identity '$IDENTITY' already installed — skipping."
    exit 0
fi

command -v openssl >/dev/null || {
    echo "error: openssl not found on PATH" >&2
    exit 1
}

# --- Step 1: dedicated keychain ---
if [ ! -f "$KC_PATH" ]; then
    echo "→ Creating dedicated keychain $KC_NAME..."
    security create-keychain -p "$KC_PASS" "$KC_PATH"
    # No auto-lock, no lock-on-sleep — keychain stays open once created.
    security set-keychain-settings "$KC_PATH"
fi

# Unlock (no-op if already unlocked; safe to call every time).
security unlock-keychain -p "$KC_PASS" "$KC_PATH"

# Add to user's keychain search list if not already there. `security
# list-keychains -d user` prints current list quoted; we append ours
# and rewrite the list so codesign/find-identity scan both keychains.
current_list=$(security list-keychains -d user | sed -e 's/^ *//' -e 's/"//g' | tr '\n' ' ')
if ! echo "$current_list" | grep -q "$KC_PATH"; then
    echo "→ Adding $KC_NAME to user keychain search list..."
    # shellcheck disable=SC2086
    security list-keychains -d user -s $current_list "$KC_PATH"
fi

# --- Step 2: generate self-signed cert ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.conf" <<EOF
[ req ]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_self

[ req_dn ]
CN = $IDENTITY

[ v3_self ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "→ Generating self-signed codesigning cert '$IDENTITY'..."
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -config "$TMP/openssl.conf" \
    -keyout "$TMP/key.pem" \
    -out "$TMP/cert.pem" \
    >/dev/null 2>&1

# macOS's `security import` uses the legacy PKCS12 PBE (RC2/SHA1). OpenSSL 3+
# defaults to AES-256/SHA256 which `security` can't verify. `-legacy`
# forces the old algo set. Non-empty p12 password dodges a separate
# empty-password MAC verification edge case.
openssl pkcs12 -export -legacy \
    -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" \
    -name "$IDENTITY" \
    -out "$TMP/cert.p12" \
    -passout "pass:$P12_PASS" \
    >/dev/null 2>&1

# --- Step 3: import into the dedicated keychain ---
echo "→ Importing cert into $KC_NAME..."
security import "$TMP/cert.p12" \
    -k "$KC_PATH" \
    -P "$P12_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    >/dev/null

# --- Step 4: whitelist codesign on the private key's partition list ---
# This is the step that prevents the GUI "Always Allow" prompt on the
# first codesign call. Empty keychain password lets us do it non-
# interactively; in the login keychain we'd have to prompt for the
# user's macOS login password here.
security set-key-partition-list \
    -S "apple-tool:,apple:,codesign:" \
    -s \
    -k "$KC_PASS" \
    "$KC_PATH" >/dev/null

# --- Verify ---
# `-v` filters out CSSMERR_TP_NOT_TRUSTED self-signed certs; we don't use
# it here because codesign works fine with untrusted local identities.
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "✓ Imported. 'make build' will sign with '$IDENTITY' on next run."
    echo "  Keychain: $KC_PATH"
    echo "  (cert is self-signed and untrusted — that's expected and fine for local dev)"
else
    echo "error: import reported success but identity not found by codesign" >&2
    echo "       run: security find-identity -p codesigning" >&2
    exit 1
fi
