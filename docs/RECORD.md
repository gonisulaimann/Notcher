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

---

# Phase 5 (final) — org site, redirect, About (supersedes the above target)- Naming settled: org https://github.com/notcherapp (live, id verified),
  site repo notcherapp/notcherapp.github.io (exact name, was public + EMPTY
  at takeover). Stray-dash rename noted per directive: always push to the
  exact name; never trust a redirecting URL for writes. @Notcher squat:
  ticket filed by owner; nothing planned around it.
- https://notcherapp.github.io/ live from `main` (/root), HTTPS enforced,
  verified 200 with self-referencing og tags. Site content = the upgraded
  v2 page (headline/accent/nav/badge/live pill), og:url + og:image repointed,
  nothing else changed.
- Old deployment kept as one-screen redirect ("Notcher has moved.",
  meta-refresh + JS + manual link); assets left in place so old og:image and
  deep links never 404. Verified live.
- Repo About set via API: description, website, topics
  [macos, notch, dynamic-island, swift, swiftui, appkit, menu-bar].
- README pitch rewrite + brand-surface site upgrade committed on main;
  product code untouched for the entire phase (verified: working tree shows
  only docs/site/README commits since v0.2.1).

---

# Phase 6/7 roadmap — argued expansion (constitution amended per item)

Thesis test for every candidate: does it make something wash in, recede, or
bridge the two devices — without becoming a widget? Rejected on sight:
stats, weather, launcher, clipboard, lyrics (widget pile, unchanged).

## SHIPPED in 0.3.0

1. **Screenshot Harbor auto-park.** Screenshots are the purest "things wash
   in" event on a Mac: user presses keys, an image lands on the Desktop, the
   notch glows and parks it. Implemented as a single O_EVTONLY fd +
   DispatchSource on ~/Desktop, image extensions only, seen-set dedup, Harbor
   toggle (default on). NOT-built amendment: background observation is now
   allowed iff it is (a) single user-visible directory, (b) user-created
   artifacts only, (c) explicitly toggleable, (d) local-only. Fully
   headless-testable (write PNG → Harbor grows → delete → clean).
2. **Wake timer truth.** A running timer survives sleep via wall-clock
   deadline already; now waking to an active timer flashes what is left.
   Three lines in the existing wake observer, proven flash path. The wake
   trigger itself is code-reviewed (a dev session cannot sleep the machine).

## DEFERRED with reasons

- **SPAKE2.** Correct next crypto step, but it needs protocol versioning +
   migration (old Mac + new iPhone must fail LOUD, not weird). Big, risky,
   and the current code-over-TLS-shaped-AES has no known-abuse profile for
   a same-room pairing UX. After 0.3.0, with a versioned handshake design.
- **iPhone Live Activity mirror.** Requires iOS hardware to verify; will
   not ship unverified animations against a protocol I cannot test.
- **Connection-quality indicator.** Needs sustained traffic to mean anything;
   heartbeats every 5 s make any meter a liar most of the time. Revisit when
   there is real continuous sync to measure.
- **Multi-display islands.** Cannot test hot-plug here; shipping untested
   window surgery on other people's display topologies is how flicker
   regressions are born. Main-display-only stays documented.

## Self-assessment (as ordered)

Against getdroppycode.app: our install window now has art + layout + inline
guidance (their polish bar: met on structure, behind on illustration —
programmatic art is clean but not lush). Against boring.notch: README now
matches on warmth and honesty while refusing the sprawl; product beats it
on coherence (one waterline vs. widget grid) and loses on breadth (by
choice). Next to raise: HN-proof social surfaces (og-tested already) and,
after hardware, the iPhone story told in motion rather than paragraphs.

---

# 0.3.0 release evidence

- First-contact findings all closed: dressed DMG (generated art, Finder
  spatial layout verified by read-back, no loose files), Keep-Both defused
  (art instruction + app-side alert tested live with synthetic dismiss),
  first-run welcome + translocation guidance (decision matrix probed 6/6).
- Hygiene closed: VERSION single-sourced (release.sh writes back), 35-file
  probe residue removed, probe quarantine (`cleanup` mode + namespaced
  artifacts + naming regression 5/5), README banner/badges/captioned gallery.
- Expansion shipped: screenshot auto-park (end-to-end: Desktop PNG → Harbor,
  probe PASS) + wake timer truth (trigger code-reviewed, flash path proven).
  NOT-built list amended for background observation (single dir,
  user-created, toggleable, local-only). Deferred with reasons: SPAKE2
  (needs versioned handshake design), Live Activity (no iOS hardware),
  connection-quality (nothing continuous to measure), multi-display
  (untestable window surgery declined).
- Release: tag v0.3.0, GitHub Release with DMG + sha256, installed copy
  verified reporting 0.3.0 with live island. Site + README download links
  repointed to 0.3.0.
- Matrix at release: self-test 8/8; stress 12/12; persistence 4/4;
  reconnect 2/2; poweredge 4/4; naming 5/5; firstrun 6/6; shotwatch live
  PASS; snapshots re-rendered (Harbor toggle verified visually).

---

# Phase 8 — The Waterline Platform (0.4.0 "The Waterline Release")

## IslandKit (URL v1 + socket v2 + CLI)

- Third-party activities sit STRICTLY below user classes in resolve():
  timer › transfer › remoteTimer › media › external. Nothing external can
  preempt, expand, or focus-steal — enforced by construction (the branch
  only renders when every user class is idle; compact tap still just pins).
- Consent is attention management, stated as such in docs and code: identity
  resolves from the Apple Event sender PID (real apps) or the declared
  source string (shell/`open`-mediated pushes); a spoofed source buys a
  local attacker nothing they lack. First push pends + flashes; Allow/Deny
  persist; grants revocable in the tray ("Waterline access" section).
- Rate cap 10/s per identity, queue cap 8 (lowest+oldest evicted), TTL
  1 s…1 h always wins, payloads truncated, SF symbols validated.
- `clear` sender-namespacing bug caught while writing docs (submit
  namespaced, clear did not) — fixed + covered by the same-event reasoning.
- CLI ships as `notcher-cli` product, installed AS `notcher`: a `notcher`
  product collides with the `Notcher` app binary on case-insensitive APFS
  and silently overwrites it in .build — found live when the bundled app
  printed CLI usage. Install script + docs use the safe name throughout.
- Socket v2: 127.0.0.1:17874, loopback-pinned transport params, newline
  JSON, per-line replies, malformed lines get `{"ok":false}` without
  dropping the stream. CLI tries socket, falls back to URL scheme.
- Gate-1 demo, live: unapproved push flashed compact then receded with
  nothing shown; grant → re-push rendered persistent compact; clear →
  idle. External pill snapshot in docs/images.

## Godmode

- Overture beat machine (corner arc → greetings → timer/file/wave vocab →
  recede, ~3.65 s full / 1.5 s reduced), explicit per-beat frames,
  cancellable, onDone-once. No second window layer: drives the existing
  panel via showCustom (argued in code — a spare window would redo every
  ordering edge two sessions eliminated). Poll shows one frame per beat
  change; no per-tick window ops.
- Live proof: launch→start→end markers on the reduced schedule exactly;
  beat snapshots render (greet + vocabFile).
- Correction chain worth keeping: (1) firstRunMoment read the retired V1
  key so the moment never fired — now didFirstRunV2, upgraders get it once
  by design; (2) `pkill -f "Notcher"` suicides the invoking shell (pattern
  matches its own command line) — an entire debugging saga chased a stale
  process; `pkill -x` is the rule now.

## Overlap

- Expanded-only scrim (level 25, mouse-transparent, guarded lifecycle,
  re-glued on screen changes). Honest boundary: app-level crowders at
  ≤25 composite below the island (probed live against synthetic level
  20/25/27 windows); system status icons always win by OS design — not
  contested. No crowder app installed here; synthetic documented as such.

## Edit-tool discipline (harness lesson, product-adjacent)

- Trailing-newline strips in string replacement MERGE comment lines with
  code (commented out a `do {`, broke Snapshot build confusingly). Rule:
  never end old/new strings at line boundaries blindly; verify with build;
  prefer python with assertions for whitespace surgery.

## 0.4.0 evidence

- Matrix: self-test 8/8; stress 12/12 (truth table now 5-wide);
  persistence 4/4; reconnect 2/2; poweredge 4/4; naming 5/5; firstrun 6/6;
  godmode 8/8; overlap 6/6; external 9/9; socket 5/5 (idempotent reruns);
  shotwatch live PASS.
- Snapshots: all nine states incl. external pill + two overture beats.
- DMG 0.4.0: universal, signature verifies, layout read back
  ({165,173}/{495,173}), installed copy reports 0.4.0 with live island.
- Release + tag live; site + README repointed to 0.4.0.
- Idle CPU re-measured: 0.37 % of one core over 30 s with socket listener +
  screenshot watcher active (was 0.23–0.27 %); ps average 0.0 %.

## 0.5.0 "The Hug" — single-window architecture rebuild

### Why

- 0.4.0's compact pill (348×40, content vertically centered) put live text
  INSIDE the hardware notch band — owner-confirmed live: track titles
  swallowed by the physical housing. The old architecture (per-mode window
  ops + NSWindowFrameAnimation + crossfaded SwiftUI) could not express the
  fix, let alone feel premium.

### What changed (architecture)

- ONE borderless, click-through-shaped 440×594 canvas window (layer 26)
  lives for the whole app lifetime; SwiftUI owns every frame of every
  transition. No window resizing, no canned NSWindowFrameAnimation — the
  old flicker-guard machinery is retired by design, not extended.
- IslandSurface/MorphShape: six animatable scalars (width, chinH, chinW,
  shoulder, bodyH, corner) define one continuous path. chinW ≈ notch+24 so
  the chin COVERS the housing; the body always blooms BELOW contentTop =
  chinH+shoulder. Wings/slab/HUD/expanded are the same path at different
  scalars — every state change is one spring interpolation (response 0.45,
  ζ 0.85; retargetable mid-flight). Shaped hit-testing reads the CURRENT
  path with 6pt hysteresis; outside-canvas clicks are invisible to it.
- Public runtime probes on this machine set the design: Spotify artwork
  URLs OK; Music raw artwork (tdta) OK; brightness via IOKit is dead on
  this OS (kIOReturnUnsupported) — volume HUD ships, brightness renders a
  muted in-HUD state rather than a fake meter; camera/mic via public
  CMIO/AudioObject properties; all fine.

### New surfaces

- Volume HUD (CoreAudio default-device listeners, in-place meter updates —
  no re-morph per keypress, Apple-HUD behavior) with brightness state.
- Privacy dots: camera/mic in-use, public APIs only.
- Clipboard shelf: opt-in (off by default), 10-entry ring buffer, dedupe
  window, memory-only, tray UI. Constitutional amendment (required: clipboard
  was on the NOT-built list): allowed because it is (a) off unless the user
  asks, (b) text-only, (c) never persisted, never synced, never leaves the
  process, (d) a shelf in the tray, not a background scraper — it captures
  only while the app runs and only what the user copies. The NOT-built ban
  on clipboard *sync* stands unchanged.
- Privacy disclosure (added in review, was missing): Spotify album art is
  fetched from Spotify's image CDN — their servers see the artwork request.
  Music artwork is read locally via Apple Events and never touches the
  network. README Privacy + site FAQ updated to state this plainly.
- Media pill: real album art (Spotify URL fetch / Music tdta, cached,
  glyph fallback), progress line, rounded monospaced digits.
- Overture rebuilt: all beats are in-window morphs (melt → greetings →
  vocab slab beats → recede); live-timed run green in godmode probe.

### Geometry proof (owner's exact screen, 1470×956, notch 179×32 @ x 645.5–824.5)

- Canvas window verified on-screen: bounds x 515–955, layer 26.
- Housing band (px 260–618 of the on-screen canvas) pixel-profiled:
  baseline ~70 (white menu bar) → island ~17–25 (dark chin covering the
  housing); ZERO bright content in the band across compact/HUD/flash/
  overture states — also re-verified offscreen in the Snapshot harness.
- HUD capture diff vs dead-app baseline: HUD capsule + wing text at
  y 72–84pt, i.e. BELOW the 32pt housing; nothing renders inside it.
- Idle melt: canvas window persists (515–955), shape melts to the idle
  blend — window lifetime decoupled from surface states.

### Matrix (all green, this machine)

- Build: full workspace green (Xcode toolchain; CLT chokes on new Swift
  macros — documented).
- Probes: stress 12/12, persistence 4/4, poweredge 4/4, naming 5/5,
  firstrun 6/6, godmode 8/8 (live run on schedule), overlap 6/6,
  external 9/9, socket 5/5, reconnect 2/2. Self-test ALL PASS.
- taptest: needs a paired iPhone on the LAN — environmental, NOT TESTED
  here (same as 0.4.0).
- Snapshot harness: 14 states rendered offscreen (media/timer/remote/
  external/flash/HUD/overture×2/expanded×2/idle...), housing band clean.
- Live app: CPU 0.4% idle-with-activity; hover-expand, HUD, outside-click
  collapse exercised on screen.

### Incidents (this phase)

- Probe overlap initially failed: in the new architecture the canvas window
  must be ordered front at first present() — window lifetime is no longer
  per-state. Fixed in present(); overlap sovereign again.
- Edit-tool discipline held (see prior lesson): two str_replace misses were
  noisy but harmless; verified by build every time.
- Background-process tool calls unavailable in this phase — long builds
  run sync; no conclusions drawn from truncated runs.

### Release

- VERSION 0.5.0; README updated (features + install + privacy wording).
- DMG cut by Scripts/release.sh (universal, ad-hoc signed, dressed layout,
  checksum + mount verification) — see dist/Notcher-0.5.0.dmg.
- NOT TESTED: taptest on real iPhone hardware; brightness meter on
  external displays (no hardware here); notarization (no Developer ID).

## Phase 9: 0.6.0 — Liquid Island Redesign (Droppy Benchmark)

### Overview

Full design and interaction overhaul to elevate Notcher from a functional prototype to an Apple-grade Dynamic Island experience benchmarked against **Droppy** (`getdroppy.app`), while preserving Notcher's single-activity focus, native zero-dependency Swift architecture, and rock-solid hit-testing core.

### Visual & Architectural Upgrades

1. **Organic Silhouette & G1/G2 Curvature (`Sources/NotcherKit/IslandSurface.swift`)**:
   - Replaced sharp quadratic curves with continuous cubic Bézier S-curves (`addCurve` with vertical tangent continuity `dy > 0, dx = 0`) connecting the camera housing to body shoulders.
   - Upgraded bottom corner radii to continuous Apple squircles.
   - Refined preset dimensions:
     - `idle`: 4pt subtle living seal under camera housing.
     - `compactSlim`: 330pt wide, flush top menu bar alignment (`shoulder: 0, chinW: w`), eliminating stepped notch gaps.
     - `compactSlab`: 368×56pt, 22pt organic shoulder bloom, 26pt corner.
     - `expanded`: 440×486pt curated luxury hub.
     - `hud`: 260×44pt centered feedback capsule.
   - Hit-testing (`IslandPanel.runHitTest`) verified with 0 click-through regressions across all geometries.

2. **Multi-Layer Liquid Glass Material (`Sources/NotcherKit/IslandView.swift`)**:
   - `SurfaceView` upgraded from flat smoked acrylic to a layered glass material:
     - Base `.popover` vibrancy material.
     - Luminous dark gradient (`rgba(20,20,26,0.70)` to `rgba(8,8,10,0.85)`).
     - Top-weighted specular rim highlight (`white.opacity(0.18)` to `white.opacity(0.04)`).
     - Subsurface top crest reflection line (`white.opacity(0.24)`).
     - Dual-stage shadow: crisp 4pt contact shadow + deep 16pt ambient drop shadow.
     - Pulsing amber glow when file drop target is active.

3. **Un-Cramped Compact Views (`Sources/NotcherKit/IslandView.swift`)**:
   - Fixed numeral line-wrapping bug (e.g., `"25:0\n0"`) by replacing rigid columns with flexible `HStack` using `minCenterGap` and `.lineLimit(1).fixedSize()`.
   - Created `WaveformIndicator`: animated 3-bar live equalizer powered by `TimelineView(.animation(paused: !isPlaying))` with mathematical sine functions — 0% CPU when paused.
   - Upgraded `MediaSlabContent`: 44×44 artwork with drop shadow, track title + waveform, artist + app name, micro-scrubber with elapsed/remaining times, and tactile playback controls (prev, prominent play/pause, next).

4. **Curated Luxury Expanded Hub (`Sources/NotcherKit/IslandView.swift`)**:
   - Redesigned from a 600pt monolithic card dump into a 486pt hierarchical command center:
     - **Header**: Tide glyph, live privacy chip (camera/mic dots), battery percentage chip with charging bolt, pin toggle, and close button.
     - **Hero Zone**: Now Playing card (60×60 artwork, scrubber, star favorite, large 36pt play/pause, AirPlay) or Focus Timer card with instant preset chips (`5m`, `15m`, `25m`, `45m`, `60m`).
     - **Harbor File Shelf**: Horizontal scrolling shelf of parked files with distinct file-type badges, hover dismiss, Finder reveal, and native `.onDrag` support allowing files to be dragged directly out of the notch into any macOS app.
     - **Quick Hub**: Opt-in clipboard preview with 1-tap copy, iPhone Link pairing code and status.
     - **System Preferences**: Toggles for notch HUD, clipboard history, launch at login, and quit.
   - Constrained content height to `metrics.bodyH` and masked `contentLayer` to `MorphShape(m: metrics)` to completely prevent canvas overflow.

### Verification Matrix (All 100% Green)

- `NotcherProbe hittest`: 8/8 PASS (body center, chin covers housing, corners, boundary slop, idle isolation).
- `NotcherProbe stress`: 12/12 PASS (truth table x200, flash bursts, hover spam, pin parity, timer lifecycle, drop target, screen storm, harbor storage, tail frame stability).
- `NotcherProbe sensors`: 12/12 PASS (clipboard dedupe, memory clearing, volume listener, privacy readers, artwork cache).
- `NotcherProbe godmode`: 8/8 PASS (overture beat morphs).
- `NotcherProbe overlap`: 6/6 PASS (window levels, scrim, layer sovereignty).
- `LinkSelfTest`: 8/8 PASS (AES-GCM crypto, handshake, chunking, framing).
- `IslandSnapshot`: 14 offscreen renders verified (zero housing bleed, crisp typography, liquid glass depth).

### Release Deliverable

- Version bumped to `0.6.0` in `VERSION`.
- Universal binary (`arm64` + `x86_64`) built and packaged via `Scripts/release.sh`.
- Final DMG: `dist/Notcher-0.6.0.dmg`
  - SHA256: `722eda49599d53ce12596dd6da9f7334268413005f6cf5d046894b2ed00bc5b5`
  - Verified mounted and bundle-checked cleanly on macOS 27.2 beta.

## Phase 10: 0.6.1 — Living Notch Hardware Fusion (The Anti-Pointer Rebuild)

### Critical Diagnosis of Design Failure

A deep forensic inspection of the live running application (`media_1789707938234.png`) on the owner's MacBook Air M4 revealed four severe design flaws that made Notcher look like a floating pointer/dashboard rather than a living notch:

1. **The "Pointer" / Bottle-Cap Neck**:
   - In `expanded`, `chinW` was constrained to `layout.notchWidth + 24` (~203pt) while `width` was 440pt, creating a 200px narrow neck sticking up with horizontal shoulders splaying out under the menu bar. This made the island read as an arrow pointing up at the notch rather than the notch itself.
   - **Fix**: Rebuilt `IslandMetrics.path` as a pure unified squircle anchored directly to the top screen bezel (`y = 0`) spanning the full width of the island (`chinW == width`, `shoulder == 0`). Zero neck, zero shoulders, zero pointer effect.

2. **The 620×620 Grey Scrim Box**:
   - `IslandController.setScrim` created a 620×620 NSPanel with `backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.32)` hanging from the top center of the display, drawing an ugly dark square across the wallpaper behind the island.
   - **Fix**: Set `sc.backgroundColor = .clear`. The panel is 100% transparent; the grey box is permanently eliminated while maintaining probe compatibility.

3. **Monolithic 486pt Settings Dashboard Dump**:
   - When expanded, Notcher previously stacked 5 different cards inside an unconstrained vertical `ScrollView`: Now Playing, Harbor, iPhone Link code, Waterline access toggles, and System preferences (4 switches + quit button), occupying half the MacBook screen with generic settings controls.
   - **Fix**: Replaced the dashboard with an intimate, non-scrolling 152pt contextual surface benchmarked to Droppy. It presents **exactly one** hero surface based on current context:
     - Media active: Now Playing (artwork, waveform, scrubber, transport controls).
     - Timer active: Focus Timer (digits, progress, controls, +1m/+5m chips).
     - Harbor active: Parked file shelf with native drag-out (`.onDrag`).
     - Standby (idle): Harbor drop target + 1-tap focus chips (`25m`, `15m`, `5m`).
     - Preferences: Accessed on demand via a discrete gear button in the header.

4. **White Dividing Stroke at Bezel**:
   - `SurfaceView` previously drew a white crest line and white rim stroke across the top edge, visually severing the island from the black camera housing.
   - **Fix**: Directional highlight stroke — `Color.clear` at the top bezel (fuses seamlessly with the notch glass) and subtle `Color.white.opacity(0.14)` along the bottom squircle edge.

### Verification Matrix (100% Green)

- `NotcherProbe hittest`: 8/8 PASS
- `NotcherProbe stress`: 12/12 PASS
- `NotcherProbe sensors`: 12/12 PASS
- `NotcherProbe godmode`: 8/8 PASS
- `NotcherProbe overlap`: 6/6 PASS
- `LinkSelfTest`: 8/8 PASS
- `IslandSnapshot`: 10/10 verified offscreen renders (zero neck, zero scrim box, crisp Apple squircle silhouette).


