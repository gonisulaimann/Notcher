# NotcherProbe (dev-only)

Drives the **live** app and stresses real windows/engines. Never bundled.

```sh
swift run NotcherProbe storm                    # burst traffic at live island
swift run NotcherProbe sendfile                 # one small labeled file, end to end
swift run NotcherProbe samplesteady <pid> <sec> # 60 Hz frame-stability audit
swift run NotcherProbe taptest                  # real click->expand, Esc->collapse
swift run NotcherProbe stress                   # in-process window/state storm
swift run NotcherProbe persistence              # timer relaunch round-trips
swift run NotcherProbe poweredge                # power-event latch regression
swift run NotcherProbe naming                   # collision-namer regression
swift run NotcherProbe firstrun                 # first-run decision matrix
swift run NotcherProbe godmode                  # overture beats + live run
swift run NotcherProbe overlap                  # scrim lifecycle + z-order vs crowders
swift run NotcherProbe external                 # consent/TTL/eviction/priority/revocation
swift run NotcherProbe socket                   # loopback socket vs live server
swift run NotcherProbe shotwatch                # desktop PNG parks in Harbor (live app)
swift run NotcherProbe reconnect                # kill + re-establish session
swift run NotcherProbe cleanup                  # delete probe artifacts from live inbox
```

`storm` / `sendfile` / `taptest` write REAL files to the live
`~/Downloads/Notcher Inbox` (that is the point — end-to-end proof). Every
artifact matches a known prefix (`Note from Probe*`, `notcher-probe-note*`,
`Notcher probe tap*`); run `cleanup` afterwards. Harbor dead-entries prune
themselves on the next app launch — relaunch Notcher to finish.

`storm` / `sendfile` pair over Bonjour using the live pairing code (read via
`CFPreferences`, never typed) and intentionally cause visible product
behavior. `stress` / `persistence` back up `~/Library/Application
Support/Notcher/{timer,harbor}.json` first and restore afterwards.
