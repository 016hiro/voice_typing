# Release Process

> Audience: maintainer (you).
> Scope: v0.6.0 onward (DMG + Sparkle auto-update).
> Earlier versions shipped from source — those instructions live in [`README.md`](../README.md) under "Build".

## TL;DR per release

```bash
# 1. Bump Info.plist (CFBundleShortVersionString + CFBundleVersion)
# 2. Update CHANGELOG.md / write devlog
make release VERSION=0.6.1 BUILD=22

# 3. Push the artifacts (instructions are printed by the previous step)
gh release create v0.6.1 build/VoiceTyping-0.6.1.dmg \
    --title 'v0.6.1' --notes-file docs/devlog/v0.6.1.md
(cd build/gh-pages && git add appcast.xml && git commit -m 'appcast: v0.6.1' && git push)

# 4. Verify on a clean install (or a 2nd Mac if available):
#    open Sparkle's "Check for Updates…" → confirm the new version detects.
```

## One-time setup

Skip if already done.

### 1. Sparkle CLI tools

```bash
make setup-sparkle-tools
```

Downloads + extracts `sign_update`, `generate_keys`, `generate_appcast` into `.build/sparkle-tools/bin/` (gitignored).

### 2. EdDSA signing keypair

```bash
.build/sparkle-tools/bin/generate_keys
```

Behavior:
- macOS Keychain prompt: "generate_keys wants to use the login keychain" → **Always Allow**.
- Stores the **private key** under account `ed25519` in the login Keychain.
- Prints the **public key** to stdout — paste it into `Resources/Info.plist` as `SUPublicEDKey`.

**Back up the private key immediately** to your password manager:

```bash
.build/sparkle-tools/bin/generate_keys -x sparkle_private_key.txt
# → save the contents of sparkle_private_key.txt to your password manager
shred -u sparkle_private_key.txt   # or `rm -P` on macOS
```

⚠️ If this private key is lost, **all existing installs become unupdatable** unless you ship a manually-installed transition build with a new pubkey baked in. Treat it like a release-signing certificate.

### 3. gh-pages worktree

The appcast lives on the `gh-pages` branch (separate from `main` so it doesn't pollute history). We work on it via a git worktree:

```bash
# Create gh-pages branch (one-time, if it doesn't exist yet)
git switch --orphan gh-pages
git commit --allow-empty -m "init gh-pages"
git push -u origin gh-pages
git switch main

# Add a worktree pointing at it
git worktree add build/gh-pages gh-pages
```

Then in **GitHub repo Settings → Pages**: Source = `gh-pages` branch, root folder. After the first push, verify `https://016hiro.github.io/voice_typing/appcast.xml` is reachable.

### 4. Initial appcast.xml

```bash
cd build/gh-pages
cat > appcast.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>VoiceTyping</title>
    <link>https://016hiro.github.io/voice_typing/appcast.xml</link>
    <description>Updates for VoiceTyping — a macOS menu-bar voice input app.</description>
    <language>en</language>
  </channel>
</rss>
EOF
git add appcast.xml
git commit -m "appcast: initial empty channel"
git push
cd -
```

`make release` will insert items into this file from now on.

## Per-release checklist

### Before `make release`

- [ ] `git status` clean on `main` (you're shipping what's committed)
- [ ] `swift test` green
- [ ] Bump `Resources/Info.plist`:
  - `CFBundleShortVersionString` → e.g. `0.6.1`
  - `CFBundleVersion` → strictly increasing integer (e.g. `22`); Sparkle compares this, not the short string
- [ ] `CHANGELOG.md` Unreleased → versioned section
- [ ] `docs/devlog/v0.6.1.md` written (gh release will use it as release notes)
- [ ] Commit the bump + changelog: `git commit -m "v0.6.1 bump"`

### Run release

```bash
make release VERSION=0.6.1 BUILD=22
```

This will:
1. `make build` → fresh `build/VoiceTyping.app` (signed with local self-signed cert)
2. `make_dmg.sh` → `build/VoiceTyping-0.6.1.dmg`
3. `sign_update -p` → EdDSA signature (read from Keychain)
4. `update_appcast.py` → insert `<item>` at top of `build/gh-pages/appcast.xml`
5. Print the next two commands you need to run

### Push

```bash
# 1. Upload DMG to GitHub Release
gh release create v0.6.1 build/VoiceTyping-0.6.1.dmg \
    --title 'v0.6.1' \
    --notes-file docs/devlog/v0.6.1.md

# 2. Push appcast.xml to gh-pages
cd build/gh-pages
git add appcast.xml
git commit -m "appcast: v0.6.1"
git push
cd -

# 3. Tag main
git tag v0.6.1
git push origin v0.6.1
```

### Verify

On the dev machine (already running an older version):
1. App should detect the update within 24h, or trigger via menu **Check for Updates…**.
2. Sparkle UI shows "v0.6.1 available" → install.
3. After relaunch, confirm:
   - `Settings → About` shows `0.6.1`
   - Microphone + Accessibility permissions still granted (TCC stable across cdhash-stable updates).

If TCC is lost: the updated app's cdhash didn't match the old one. Likely cause: signing identity changed. See "Known quirks" below.

## First install (your audience: future-you on a fresh Mac)

1. `gh release download v0.6.1 -p '*.dmg'` (or grab from Releases page)
2. Double-click the DMG → drag `VoiceTyping.app` to Applications
3. **Right-click → Open** (Gatekeeper blocks unsigned-by-Apple apps; right-click bypass works once)
4. macOS 15+ alternative if right-click is greyed out: **System Settings → Privacy & Security → "Open Anyway"** (after the first failed launch)
5. First launch: grant Microphone + Accessibility when prompted
6. From here, all updates flow via Sparkle — never need to touch DMGs again unless you reset the EdDSA key

## Known quirks

_(populate after first real upgrade verification — issue #72)_

- TBD: Confirm Sparkle's app-replace doesn't re-quarantine the new bundle (expected: doesn't, since it's a local FS swap rather than a Finder download)
- TBD: Confirm TCC grants survive the upgrade (expected: yes, because both old + new bundles signed by same self-signed cert with stable cdhash)
- TBD: macOS 15.x DMG mount warning — single right-click sufficient or settings dance required?

## Recovering from disasters

### Bad release shipped

Sparkle only goes forward. To "roll back":
1. Bump version (e.g. shipped `0.6.1` was bad → ship `0.6.2` that contains `0.6.0` code)
2. Run normal release flow

Users still on `0.6.0` are unaffected. Users on `0.6.1` get pulled forward to `0.6.2`.

### EdDSA private key lost / compromised

1. `generate_keys --account ed25519_v2` (new account name to keep them separated)
2. Rebuild app with new pubkey in Info.plist
3. Bump version, ship via DMG only — **existing installs cannot auto-update** to the new key
4. Users must manually download the new DMG once; subsequent updates resume normally
5. Document the cause in the release notes so users understand the manual install

### Apple finally requires notarization

When you eventually open a Developer account:
1. Run `xcrun notarytool submit` against the DMG
2. `xcrun stapler staple` the result
3. Update `make release` to chain those steps
4. Sparkle pipeline is unchanged — the EdDSA signature is independent of Apple's notarization
