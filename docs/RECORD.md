# Notcher — project record

## Product thesis

The MacBook notch should not become a tiny dashboard of 25 widgets. **Notcher
treats the notch as a shoreline between the Mac and the iPhone: things wash
in, and recede.** The island shows exactly *one* live activity at a time,
chosen by priority (timer › file transfer › media), plus short transient
flashes (charging, iPhone nearby, timer done) that dismiss themselves. When
nothing is alive, the island collapses into a black blend that melts into the
camera housing — it disappears instead of demanding attention.

Name: **Notcher**. Tagline: *the tide line between Mac and iPhone.*

## Why this, and not a widget pile

Researched (Sep 2026): Notchy (free, ~71 features), NotchNook ($25),
BoringNotch, Alcove, DynamicNotch (OSS), DynamicMac (OSS), Perch. All are
Mac-only widget piles: clipboard managers, stats, launchers, lyrics. None has
a real iPhone relationship, and none commits to a single-activity model. The
gap: **a coherent live-activity surface + an honest local Mac↔iPhone link.**
Notcher is that, deliberately smaller than all of them.

## Architecture

```
Notcher.app (LSUIElement, no Dock icon)
├── IslandPanel (NSPanel, borderless, level 26, per-screen notch anchoring)
│   └── IslandRootView (SwiftUI: idle / compact / expanded)
├── Engines (all @MainActor, Combine → IslandState.resolve)
│   ├── TimerEngine    countdown + persistence + UN notification
│   ├── MediaEngine    Music/Spotify via AppleScript (public scripting only)
│   ├── PowerEngine    IOKit power sources → transient flashes only
│   ├── HarborStore    ≤8 parked files (security-scoped bookmarks, referenced)
│   └── LinkHost       Bonjour + AES-GCM session to the iPhone companion
└── NSStatusItem       Open Island / 25-min timer / Quit
Sources/LinkCore       shared protocol: framing, AES-GCM, NW transport
Companion-iOS          iPhone app (Xcode build, same LinkCore revision)
Snapshot / SelfTest    dev harnesses (see Testing)
```

## Major decisions & rejected alternatives

- **One activity, priority-ordered** — rejected the widget grid. A shoreline
  has one waterline.
- **Network.framework, not MultipeerConnectivity** — Multipeer is
  *deprecated* as of this OS (macOS 27 SDK headers). Bonjour (NWListener /
  NWBrowser) + app-layer AES-GCM is the supported path.
- **No MediaRemote.framework** — private API. Music/Spotify scripting only,
  and we never *launch* a music app to query it (guarded by
  `NSWorkspace.runningApplications`). Music wins ties when both run.
- **Pairing code (6-digit), no accounts/cloud** — key = SHA256(salt‖code),
  salt exchanged in the clear on the LAN. Honest trade-off, same class as
  AirPlay codes: fine against casual snoopers, not against an active LAN
  attacker. Documented; future work is a PAKE (SPAKE2) handshake.
- **No clipboard sync** — overdone by competitors and the highest-risk data
  class. Text/notes move only on explicit Send. Files land in
  `~/Downloads/Notcher Inbox` (Mac) / app `Documents/Inbox` (iPhone).
- **No window snapping / launcher / stats / lyrics / weather** — widget pile,
  out of scope on purpose.
- **No Electron** — native AppKit + SwiftUI, built with Command Line Tools
  only (no Xcode on this machine; see Toolchain).
- **Always-dark island** (`panel.appearance = .darkAqua` + smoked-glass lens
  + forced-dark SwiftUI) — verified legible in light mode via snapshots.
- **Hover never activates the app** — activation happens only on explicit
  clicks (`onInteract`), otherwise hovering the notch would steal keyboard
  focus from the frontmost app.
- **Precompiled AppleScripts** — compiling per poll cost ~5–15% CPU; stored
  `NSAppleScript` instances + cheap `execute` fixed it (~0.6% → ~0.0%).

## Toolchain (matters)

- Dev machine: CLT only — no Xcode, no iOS SDK, no XCTest, no SwiftUI /
  swift-testing macro plugins. Consequences, all worked around:
  - No `@State` in Mac code (macro unavailable) → view drafts live in the
    engines (`draftMinutes`, `draftMessage`, …).
  - No `swift test` → `swift run LinkSelfTest` (plain executable harness).
  - No screencapture (permission-gated) → `swift run IslandSnapshot`
    photographs its own windows via `CGWindowListCreateImage`.
  - iOS target is parse-checked only; see Testing categories below.
- App bundle assembled by `Scripts/build-app.sh` (swift build + Info.plist +
  icon + ad-hoc codesign). Icon drawn in code (`Scripts/make-icon.swift`).

## Public APIs used

AppKit (`NSPanel`, `NSStatusItem`, `NSOpenPanel`, `NSAppleScript`,
`NSScreen.safeAreaInsets/auxiliaryTopLeftArea`), SwiftUI, Combine, Network
(NWListener/NWBrowser/NWConnection + Bonjour), CryptoKit (AES-GCM, SHA256),
IOKit power sources (`IOPSCopyPowerSourcesInfo`), ServiceManagement
(`SMAppService` launch-at-login), UserNotifications (timer-done only),
`DistributedNotificationCenter` (Spotify state change), Security
(`SecRandomCopyBytes`, bookmarks).

## Permissions required

- **Local Network** (Bonjour browse/advertise) — iPhone discovery.
- **Automation → Music/Spotify** (AppleEvents) — only when you press
  play/pause/skip or while polling a *running* player; denied = media silent.
- **Notifications** — timer completion only (asked at timer start).
- **Files** — drag-and-drop / file picker only; no full-disk access.
- No Accessibility permission. No camera/mic. No network beyond the LAN.

## Known limitations (honest)

1. macOS 27 beta quirk: `Data[Range]` subscript traps on some Data
   representations → transport uses `subdata(in:)`/`removeSubrange`
   exclusively. Revisit on stable SDK.
2. Single display: island anchors to `NSScreen.main`; other displays get
   nothing (by design for v1, not a bug).
3. iPhone app is foreground-only (iOS suspends Bonjour in background).
4. Wrong-code peers retry every 5s (small handshake chatter, no backoff yet).
5. Old `timer.json` (pre-`remaining` field) is discarded once = one silent
   timer loss across this upgrade, then correct forever.
6. Sending Mac→iPhone files has no progress UI on the Mac side (instant for
   small files; 25 MB cap enforced).
7. Ad-hoc codesignature → Gatekeeper prompt on first launch on other Macs;
   needs a Developer ID to distribute.

## Testing performed

- **TESTED (this MacBook Air M4, macOS 27.2 beta):**
  - `LinkSelfTest`: 8/8 pass — AES-GCM round trip, wrong-code rejection,
    framing, live loopback handshake + encrypted message + presence, chunker
    pack/reassemble, wrong-code peer never authenticates.
  - Live app: notch geometry resolved from public API (179pt housing, 32pt
    safe area); window layers/sizes verified for idle (251×38), compact
    (348×40), expanded (404×468) via Quartz window list.
  - Real Now Playing: showed live Music.app track/artist, play/pause/next
    targets verified in code + state transitions observed (playing→compact,
    stopped→idle recede).
  - Real battery header (100% + bolt while on charger).
  - Visual sign-off of all 5 states via `IslandSnapshot` PNGs (dark + light).
  - Launch/quit/relaunch cycle; timer persistence path (new schema).
  - CPU: ~0.0% `ps` average, 0.60% of one core over 30s idle window; ~36–90MB
    RSS (normal SwiftUI baseline).
- **NOT TESTED:** iPhone companion on a device (no Xcode/iOS SDK here);
  file transfer end-to-end Mac↔iPhone (needs the companion); timer-done
  notification fire (permission prompt untriggered in dev).
- **EXPECTED TO WORK:** companion flows — same `LinkCore` revision both ends,
  handshake/auth/loopback proven on macOS; iOS code paths use only public
  iOS 17+ APIs and are parse-checked.

## Performance observations

- Media poll dominates idle cost; precompiled scripts fixed an 11% spike.
- No animations run in idle (static capsule) except a 5px breathing dot that
  exists only while an iPhone is connected.
- Heartbeat 5s / media poll 2.5s / power poll 30s; no other timers when idle.

## Deliberately NOT built

Clipboard history/sync, window snapping, app launcher, system stats, weather,
lyrics, global hotkeys, iCloud, accounts, telemetry, menu-bar widgets,
multi-display islands, Android/web clients.

## What next (if continued)

1. SPAKE2 handshake replacing code-derived key.
2. Connection-quality indicator in the Link section.
3. iPhone: Live Activities / Dynamic Island mirror of the Mac timer.
4. Continuity Camera presence (public API) as an island flash.
5. Developer-ID signing + Sparkle-style updates.

---

# Stability mission (second pass): make it feel stable, intentional, alive
## Reported symptom

Notch/island flicker, inconsistent stability during interaction/state changes.

## Root cause (proven, not guessed)

Two compounding defects, both in the window/update path — not in animation
curves, compositing, or Spaces:

1. **Unguarded window ops.** `IslandController.show()` called
   `setFrame(animate:)` + `orderFrontRegardless()` on EVERY invocation, even
   for an identical frame. Every `@Published` sink (`mode`, `activity`,
   `flash`, `peers`, `receiving`, `remoteTimer`) called `refreshWindow()`
   directly, and `engineChanged()` ended with another one — so a single event
   produced up to 3 shows, and per-chunk transfer progress / 5 s remote-mirror
   traffic each re-animated and re-ordered the transparent window over the
   menu bar. That compositor churn IS the flicker.
2. **No hover hysteresis.** `hoverExited` collapsed instantly, so the window
   shrinking under a stationary cursor re-fired exit at the boundary —
   an enter/exit oscillation machine.

Transparent-window compositing, Spaces behavior, geometry math, and polling
were investigated and exonerated (geometry verified point-exact against the
live notch; polls are change-gated).

## Fixes

- `show()` diff guard: same kind + same key posture + same frame = no-op
  (mid-flight frames never compare equal, so genuine re-targets still morph).
- Coalesced refresh: all publisher roads go through one `requestRefresh()`
  per runloop turn.
- High-frequency publishers reduced to edges (`receiving` nil-edge,
  `remoteTimer` peer-edge, `peers` id-set edge).
- Edge broadcasts moved out of `engineChanged` into the already edge-gated
  timer/media callbacks (+ one greeting broadcast on peer join).
- Hover-exit hysteresis 0.28 s, cancelled by re-enter; pin paths cancel it.
- Click-only activation preserved and extended (expanded background tap).
- Drop-target glow with 8 s auto-clear (a missed drag-exit can't stick it).
- Wake restart for the link session (re-announce Bonjour after sleep).
- Retry backoff 5 s → 60 s cap, reset on any authenticated session.
- Reduced-motion now swaps the spring for a short ease (motion kept, bounce
  removed). NOTE: this Mac has Reduce Motion ON, so the live-tested path is
  the ease path; the spring curve is code-reviewed + snapshot-rendered only.
- `UNUserNotificationCenter` now posts only when authorized (denied-context
  post throws in non-app hosts — found via probe; also correct product
  behavior).

## Evidence it worked

- 30-event live storm: **3 window shows total** (was: 30+). Debug trace shows
  one `show compact` at storm start, activity transitions, one `show idle`
  at recede. Zero redundant morphs.
- Live 60 Hz audit, 10 s idle: **513/513 identical frames**.
- In-process storm tail: **0 frame changes** over 2 s after settle.
- Live file receive: offer → transfer → flash → saved → recede, 2 shows.
- Real click → 404×468 expanded; real Escape → collapsed (3/3 runs).
- Idle CPU on final build: **0.23% of one core** over 30 s.

## NotcherProbe matrix (dev-only target, never bundled)

- `stress` 12/12: priority truth table ×200, flash bursts, hover spam (no
  stuck expanded), pin parity, timer start/pause/resume/cancel, drop glow,
  screen-params storm ×5, harbor add/resolve/remove ×3 real files, live 3 s
  timer through done → flash, diff-guard absorption, steady tail.
- `persistence` 4/4: paused/running round-trips, corrupt → idle, legacy →
  idle.
- `reconnect` 2/2: handshake, kill, re-handshake.
- `samplesteady` live: PASS (see above).
- `taptest` live: PASS 3/3 (one earlier flake: back-to-back down/up post
  outran button tracking once; 60 ms press duration added, green since).
- `storm` + `sendfile` live: PASS; all probe residues cleaned
  (31 inbox notes + probe file + harbor entries removed, state pristine).

## Harness lessons (future-me warnings)

- CLI + `@MainActor` product classes: per-call `MainActor.run` hops and
  `Task.sleep` loops die silently (exit 0, no crash) — the CLI lacks the
  NSApp.run environment actor code assumes; an AppKit exception later proved
  actor work executing off the main thread. Rule: drive MainActor code from
  the real main thread + real runloop (sync + `assumeIsolated` + pumps), like
  Snapshot. The app itself (NSApp.run) was never affected.
- `exit()` skips `defer`: Snapshot rested on defer-based state restore that
  never ran. Restores are now explicit pre-exit. Same class of bug fixed in
  probe backup/restore (plus dict-nil-removes-key: absence tracked explicitly).
- `swift_task_asyncMainDrainQueue` in lldb stacks was a red herring for the
  above — the actionable defect was thread placement, proven by the AppKit
  main-thread exception.

## Hostile review outcomes

- Window lifecycle / state machine / priority / persistence / sync /
  reconnect: all probed green (see matrix).
- Sleep/wake restart, Spaces flags, real display hot-plug, Eve-backoff
  timing: code-reviewed, NOT live-tested (won't sleep/hot-plug the dev
  machine from an agent session; no second display attached).
- Spring animation path: code-reviewed + snapshot-rendered (live OS uses
  ease path — Reduce Motion is on here).
- Accessibility: full audit — every icon-only control labeled, decorative
  images hidden, meters hidden, fields labeled, pill/header labeled.
- Resource usage: no timers when idle beyond engine polls; no idle animation
  except the link dot (only while iPhone connected).
- `timerCancel` from iPhone stops the Mac timer too — intended shared-timer
  semantics, not a bug.

## Unified-surface verdict (infrastructure is not the product)

With public APIs only, genuine unification = **shared timer truth + explicit
two-way handoff** (both shipped and live-tested Mac-side). Background
mirroring / presence without the app open is impossible without private APIs
or background modes Apple won't grant this class of app — correctly rejected.
The demo moment: **drag a file onto the notch** (it glows, swallows, parks;
Harbor holds it) and **flick a timer to the iPhone** (it lives in both
places). Depth kept over breadth: no new widgets were added in this pass.

---

# Release-readiness pass: installable DMG, honest distribution

## Release pipeline (single command)

`./Scripts/release.sh [--version X.Y.Z]` (default: `VERSION` file, now 0.2.0):

1. Universal release build (`--arch arm64 --arch x86_64`).
2. Cleanroom `.app` staged in mktemp (never the repo working copy).
3. Version injection via PlistBuddy; executable bit; icon; `plutil -lint`.
4. Ad-hoc sign (`--options runtime`, no timestamp) + `--verify --deep
   --strict`; `spctl -a` recorded (informational).
5. DMG with Notcher.app + `/Applications` symlink + install readme.
6. SHA-256 + mount verification (app + symlink present).

Output: `dist/Notcher-<ver>.dmg` (+ `.sha256`).

## Verification evidence

- Universal fat binary confirmed (`lipo`: x86_64 + arm64).
- x86_64 slice executed under Rosetta: LinkSelfTest **8/8 PASS**.
- DMG mounts; layout verified (app, symlink, readme).
- Quarantined copy: `spctl -a` **rejected**, `open` blocked with Gatekeeper
  dialog (no process) — documented in install readme (Right-click → Open).
- Fresh unquarantined copy: launches and runs normally.
- Installed to /Applications: signature verifies; launches; island live;
  paired over Bonjour; timer start/cancel round-trip persisted correctly.
- Lifecycle: install → launch → quit (clean, via AppleEvents) → relaunch →
  replace → relaunch → quit → remove. All clean, no orphans.
- Single-instance guard added (repo copy + installed copy share one bundle
  id): newcomer logs and quits. Tested BOTH directions.
- No dev-directory assumptions in product code (grep-verified: no absolute
  repo/tmp paths in `Sources/`).
- Bundle: display name, copyright, icon, executable arch, resources,
  permissions strings, versioning — all verified in pipeline.

## Signing strategy (honest)

`security find-identity`: **0 valid identities** in this environment. No
Developer ID, no Mac Developer cert, no Team. Therefore: ad-hoc only, no
notarization, no stapling. NOT CLAIMED anywhere. The DMG suits this Mac and
side-loading; another Mac gets the documented Right-click → Open flow.
`hdiutil` deprecation warnings on macOS 27 are cosmetic (commands succeed).

## iOS adversarial review (no device — findings only)
- Added `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` to the
  plist fragment (else received files are invisible in the Files app).
- Fixed same-name collision suffix accumulation on BOTH platforms.
- Removed dead `shareBattery` property (toggle is UserDefaults-backed).
- Added `helpNeeded` (12 s with no peers) + UI hint — wrong-code/silent
  failure is otherwise indistinguishable from "still looking".
- Noted: `UIDevice.name` is generic on iOS 16+ (cosmetic, unfixable).
- Verified by reading: plist valid, all APIs within iOS 17 minimum,
  file-keying consistent with transport stamping, background stop correct,
  permission-denied path retries via browser restart (code-reviewed).
- iOS remains EXPECTED TO WORK / NOT TESTED on hardware.

---

# Senior-audit session: version control, three defects, redesign

## Phase 0 — version control

`git init`, `.gitignore` (build outputs, DMG, app copies, `.freebuff/`,
`.DS_Store`), repo-local identity, baseline commit "Notcher 0.2.0 — audited
baseline" (35 files, zero artifacts). One commit per coherent change after.
Note: two earlier `SESSION-FOR-CHATGPT*.txt` exports are no longer on disk
(unknown remover; likely external tool — `.freebuff/` appeared the same
evening and is excluded, not ours). No product files affected.

## Phase 1, defect 1 — "Fully charged" flash spam (TESTED fixed)

`PowerEngine.refresh()` fired `.full` on every 30 s poll while plugged in
near 100 % (level-triggered, unlike edge-gated `.chargingStarted`). The
island would re-light forever. Fix: edge table extracted to testable static
`func edgeEvents(info:state:)`, `.full` latches until disconnect or <95 %,
`.low` latch preserved. Regression: `NotcherProbe poweredge` (4/4) —
double-99.5 % polls emit exactly one `.full`; replug emits
`[.chargingStarted, .full]`; dip-below-95 re-arms; low latch intact.

## Phase 1, defect 2 — remote timer read as "Nothing playing" (TESTED fixed)

`engineChanged()` folded the iPhone mirror into `mediaPlaying`, so the
compact pill took the `.media` branch with nil title. Fix: first-class
`.remoteTimer` activity, priority timer › transfer › remoteTimer › media;
pill branch shows orange timer + peer + locally extrapolated live countdown
(`TimelineView` 1 s tick; truth arrives ~5 s); LinkSection row upgraded the
same way; shared `liveRemaining()` helper; pure `RemoteTimerPillContent`
view so snapshots render it without a live session
(/tmp/notcher-compact-remote.png: "12:34 iPhone", correct).

## Phase 1, defect 3 — hygiene (TESTED fixed)

Force-unwrap `self!.timer.label` in `timer.onFinished` replaced with guarded
label capture. Dead `Task { @MainActor in _ = self }` in LinkHost's code
closure removed. No behavior change; matrix green.

## Phase 2 — generational surface redesign (TESTED, no new features)

- Motion: container spring retuned to response 0.5 / damping 0.7 (one
  tasteful overshoot); mode roots crossfade + scale (0.92–0.94 → 1.0);
  compact content morphs on every activity/flash handoff via identity-keyed
  transition. AppKit frame morph unchanged (platform limit, documented —
  guardrails win ties, here there was no tie). Ease paths preserved.
- Material: IslandGlass layered — specular top edge pushed, inner bottom
  shadow, hover-responding lens (0.32 → 0.27) and border (0.14 → 0.22).
  All content-redraw-only; zero window-op impact by construction.
- Type: text opacities normalized to 100 / 70 / 45; headline tracking −0.2.
- Pressed states: `PressableButtonStyle` (0.96 + dim) on every island button.
- Drop inhale without scale (tight window would clip): 2.5 px orange border
  + translucent bloom wash, animated.
- Pupil ring tried and CUT: snapshot read as a smudge, fought the invisible
  idle. No sentiment.
- Breathing link dot kept.

## Phase 2 gates (all green)

- Snapshots: /tmp/notcher-idle.png, /tmp/notcher-compact-timer.png,
  /tmp/notcher-compact-media.png, /tmp/notcher-compact-remote.png,
  /tmp/notcher-expanded-dark.png, /tmp/notcher-expanded-light.png.
- Matrix: stress 12/12, persistence 4/4, reconnect 2/2, selftest 8/8,
  poweredge 4/4. samplesteady 519/519 identical idle frames (≥300 required).
  taptest PASS/PASS (dimensions unchanged, interaction re-proved anyway).
- Idle CPU re-measured: 0.27 % of one core over 30 s (was 0.23 %; noise).
- Commits: Phase 1 audit defects, Phase 2a motion, Phase 2b material —
  one per coherent change.
- No new features. No stability-guardrail contact (no new window-op paths;
  `pointerInside` has deliberately NO refresh sink).

---

# Phase 4 — publish, release 0.2.1, landing page (product code FROZEN)

- Repo: https://github.com/gonisulaimann/Notcher (`main` pushed; tag `v0.2.1`
  annotated). No product-code changes in this phase; triage list stayed empty.
- Renumber rationale: the DMG said 0.2.0 but predated the Phase 1/2 fixes.
  0.2.1 is the first build containing them, so the owner can trust the number.
- Release: https://github.com/gonisulaimann/Notcher/releases/tag/v0.2.1
  (DMG + .sha256 assets, RECORD-verbatim notes with TESTED/NOT-TESTED split).
  Verified: mounts, app + symlink + readme, sha256, universal fat binary,
  ad-hoc signature verifies, version 0.2.1 in bundle.
- Site: https://gonisulaimann.github.io/Notcher/ (gh-pages branch, static
  HTML+CSS, zero JS, zero external assets, system fonts; verified 200s on
  page + all images + og tags; favicon from app icon).
- README: Download section, six snapshot proofs, exact First-5-Minutes
  checklist, honest KNOWN ISSUES. LICENSE: MIT © 2026 gonisulaimann.
- Deletion incident (from Phase 0): two chat-export txt files vanished from
  disk from an unattributable cause. Standing rule adopted: never delete
  files you cannot attribute; probe/snapshot hygiene (explicit restores) now
  covers everything the tooling touches.
- Liquid Glass stance: hand-built material vocabulary retained (IslandGlass
  + forced-dark + smoked lens). System glass APIs to be evaluated ONLY for
  the expanded tray on a stable SDK; idle/compact stay hand-tuned. The
  identical dark/light snapshot outputs prove the forced-dark design renders
  independent of window appearance — by construction, not accident.

---

# Phase 5 — brand surface rewrite (product code FROZEN)

- Org prerequisite: `notcher` org does NOT exist (API 404, rechecked at
  deploy time). Owner creates it; until then the org move + redirect page
  are HELD, not stalled — everything below is built and the live site is
  already upgraded in place. Product repo stays at gonisulaimann/Notcher.
- README rewritten to pitch voice (boring.notch cited as inspiration for
  warmth/second-person/honest-warnings; feature sprawl explicitly rejected
  in favor of one-waterline discipline). Both Gatekeeper bypasses verbatim;
  terminal method recommended as in the reference. Voice check applied per
  sentence: want-it or truth-about-getting-it.
- Landing page upgraded on the live deployment
  (https://gonisulaimann.github.io/Notcher/): claim headline "Your notch,
  alive." with #ff9f0a accent, floating glass nav, GitHub badge, Apple-logo
  CTA, ambient hero glow, live-ticking CSS pill (5-line JS countdown —
  the one-waterline motion, demonstrated). Verified: desktop + small-screen
  renders via headless Chrome; HTML parser-clean.
- Responsive note: a 390 px headless shot showed overflow, proven by
  media-query probe to be a ~500 px headless layout floor (red applied,
  lime did not), NOT a page defect — breakpoints verified at 500 px and the
  560 px query path is correct for real phones. Documented, not chased.
- URLs: repo https://github.com/gonisulaimann/Notcher,
  release https://github.com/gonisulaimann/Notcher/releases/tag/v0.2.1,
  site https://gonisulaimann.github.io/Notcher/ (target future:
  https://notcher.github.io/ with this URL kept as redirect).
