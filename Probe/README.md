# NotcherProbe (dev-only)

Drives the **live** app and stresses real windows/engines. Never bundled.

```sh
swift run NotcherProbe storm                    # burst traffic at live island
swift run NotcherProbe sendfile                 # one small labeled file, end to end
swift run NotcherProbe samplesteady <pid> <sec> # 60 Hz frame-stability audit
swift run NotcherProbe taptest                  # real click->expand, Esc->collapse
swift run NotcherProbe stress                   # in-process window/state storm
swift run NotcherProbe persistence              # timer relaunch round-trips
swift run NotcherProbe reconnect                # kill + re-establish session
```

`storm` / `sendfile` pair over Bonjour using the live pairing code (read via
`CFPreferences`, never typed) and intentionally cause visible product
behavior. `stress` / `persistence` back up `~/Library/Application
Support/Notcher/{timer,harbor}.json` first and restore afterwards.
