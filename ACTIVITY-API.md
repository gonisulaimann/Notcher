# IslandKit — the waterline API

Anything on your Mac can surface one live activity on the notch: build
scripts, downloads, timers, deploys. One rule governs everything: **user
activity always wins**. A third-party activity only ever shows while the
island would otherwise be idle, it can never steal focus or expand the tray,
and its first push asks for your consent first.

## The 60-second version

```sh
# 1. Push (the island flashes a consent request — nothing shows yet)
open "notcher://activity?title=Deploying&subtitle=api%20to%20prod&ttl=5m&source=cli"

# 2. Hover the notch, open the tray, Allow it under "Waterline access"

# 3. Push again — the pill is yours
open "notcher://activity?title=Deploying&progress=0.4&ttl=5m&id=deploy&source=cli"

# 4. Update by reusing the id; finish by clearing it
open "notcher://activity?title=Deploying&progress=1.0&id=deploy&source=cli"
open "notcher://clear?id=deploy"
```

Or install the CLI once (`./Scripts/install-cli.sh`) and skip URL-encoding:

```sh
notcher push "Deploying" --subtitle "api to prod" --progress 0.4 --ttl 5m --id deploy --source cli
notcher clear --id deploy
```

## Parameters (`notcher://activity`)

| param | meaning | limits |
|---|---|---|
| `title` | headline (required) | 120 chars, truncated |
| `subtitle` | second line | 200 chars, truncated |
| `progress` | 0..1 meter | clamped; omit for no meter |
| `ttl` | seconds, or `90s` / `5m` / `2h` | 1 s…1 h, default 2 min |
| `priority` | `low` / `normal` / `high` | orders third-party queue only |
| `id` | stable id for updates | same id replaces; omit for one-shot |
| `source` | display name ("Chef", "ffmpeg") | 60 chars; consent is keyed on it (or bundle id for real apps) |
| `icon` | SF Symbol name | validated; falls back to `app.badge` |

`notcher://clear?id=X` ends one of your activities; `notcher://clear` ends
all of them. Ids are namespaced per sender, so you can only ever clear your
own — one script cannot cancel another's pill.

## Consent model (attention management, not sandboxing)

First push from an unknown source → the island flashes
**"X wants the waterline"** and queues the request. Nothing renders until
you Allow it in the tray. Deny drops silently from then on. Every grant is
listed under "Waterline access" and revocable with one toggle. Rate cap:
10 pushes/second per source; queue cap 8 activities (lowest priority and
oldest evicted first); TTL expiry always wins. A local process that wanted
to misbehave could already do far worse than a notch pill — consent exists
so your attention stays yours, not as a security boundary.

## Priority

`timer › transfer › remoteTimer › media › external`. Third-party activities
among themselves: `high › normal › low`, then most recent. Transient by
default; TTL expiry recedes to whatever is next in line.

## Examples

See `Examples/`: `build-watch.sh` (wrap any command), `download-watch.sh`
(`curl` with live progress), `pomodoro.sh` (25/5 focus loop).
