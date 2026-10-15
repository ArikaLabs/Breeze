# Breeze

Local control for Midea air conditioners from the Mac menu bar. An Arika Labs product.

## Read first
- `README.md`: what it does, how it is built, the protocol table, what leaves the Mac.
- `REVIEW.md`: what counts as a finding in a review.
- The Arika Labs house style: `Sources/Breeze/Theme.swift` holds the Swift tokens; the guide itself is the Arika Labs design system, kept outside this repository. `site/index.html` is the landing page in the same style, with a live replica of the panel.

## Layout
- `Sources/MideaKit`: the protocol. Discovery, 0x8370 framing, AES/MD5/SHA256, 0xAC frames, SmartHome cloud token. Pure Swift, no UI.
- `Sources/MideaCLI`: `midea-cli`.
- `Sources/Breeze`: the app. AppKit status item + NSPopover + SwiftUI views, App Intents, thermal monitor, energy log.
- `Tests/MideaKitTests`: byte-exact vectors generated from msmart-ng, plus an in-process fake unit.
- `scripts/`: `build-app.sh` (bundle, App Intents metadata, icon, signing), `make-dist.sh` (DMG + zip, optional notarization), `make-icon.swift`, `Info.plist`. `Resources/`: the stone textures. `site/`: the landing page and its assets.

## Commands
`swift test` · `./scripts/build-app.sh [--install] [--run]` · `./scripts/make-dist.sh` (`NOTARY_PROFILE=…` notarizes) ·
previews: `BREEZE_DEMO=1 BREEZE_PREVIEW=1 BREEZE_APPEARANCE=light|dark BREEZE_SNAPSHOT=out.png [BREEZE_SNAPSHOT_SCALE=2] [BREEZE_SNAPSHOT_SETTINGS=settings.png] build/Breeze.app/Contents/MacOS/Breeze` (add `BREEZE_DEMO_POWER=off`, `BREEZE_DEMO_TEMP=22.5`, `BREEZE_DEMO_SWING=both`, `BREEZE_DEMO_HOT=1`, `BREEZE_DEMO_UNITS=1` as needed).

## How work gets done
1. A protocol change starts from a captured frame or a reference implementation and lands as a vector in `Tests/MideaKitTests/vectors.json` before the code that satisfies it.
2. A UI change is checked with preview snapshots in both themes before it is committed; the landing page's live panel (`site/index.html`) is updated when the real panel changes.
3. Work on a `claude/*` branch and open a PR with the commands run, their output and the snapshots. Never push to main.
4. `README.md` and the landing page's model table stay truthful: "tested" means someone linked that unit and used it.

## Rules (each one exists because breaking it causes real damage)
- **Device tokens and keys never enter the repo, a log line, a screenshot or a chat message.** They live in `~/Library/Application Support/Breeze/credentials.json` (0600) or the Keychain. `midea-cli` prints them only for an explicit `token` command.
- **Never weaken, skip or delete a protocol test to get green.** The vectors are the contract with the unit; a wrong byte bricks nothing but silently stops control.
- **Every colour comes from `Theme`; no neutral greys, no borders on cards, both themes always.** Add a token rather than a literal.
- **No new network destination.** The app talks to the unit's LAN address and, once at setup, to Midea's SmartHome login. Anything else is a privacy change the owner decides.
- **Nothing public without the owner.** Creating repos, releases, deployments or posts is the owner's call each time.
- **Don't edit `.github/workflows/`.** Propose the change in your summary; a human makes it.
