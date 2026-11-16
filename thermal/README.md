# Immich thermal + stability profile

Written 2026-09-17, while pihome sat at **85.6 C, clocked down to 1.5 GHz from 2.4**,
mid-backfill on an 18,696-asset photo library.

## What was actually wrong

Not the photo upload. Immich's **ML backfill** was running six workers against three
pinned cores:

| queue | active | waiting |
|---|---|---|
| thumbnailGeneration | 2 | 1,512 |
| facialRecognition | 1 | 358 |
| ocr | 1 | 167 |
| faceDetection | 2 | 50 |

`immich_machine_learning` held four ONNX models resident at once (`buffalo_l` detect +
recognize, `PP-OCRv5_mobile`, `ViT-B-32__openai`) at 176% CPU; `immich_server` added
115%. That is the entire `cpuset: "0-2"` budget, with `throttled=0xf0006` — soft temp
limit reached, frequency capped.

Three findings that shaped the fix:

1. **The queues were growing, not draining.** Over 90 s: thumbnails −42, but
   faceDetection +22, facialRecognition +23, ocr +24. Every finished thumbnail enqueues
   three downstream ML jobs, and ML could not keep up while fighting libvips for cores.
   The backlog compounds, which is why it sat at 85 C indefinitely instead of finishing.

2. **`cpuset` is affinity, not a limit.** Both containers could saturate all three
   pinned cores. Only a hard `cpus` quota keeps the SoC off the trip point — and it is
   *free*:

   ```
   throttled:  3   cores x 1.5 GHz = 4.5 core-GHz
   capped:     2.5 cores x 2.4 GHz = 6.0 core-GHz   <- ~33% faster, and cooler
   ```

3. **The 00:00 nightly job is the trigger.** BUILD-LOG's earlier entry listed this as
   "unconfirmed"; the queue mix here (`missingThumbnails` cascading into faceDetection →
   facialRecognition → ocr across all 18,696 assets) matches it exactly. Hence the 23:30
   night switch below.

4. **Context switches ran at 98k–139k/s.** The ML container defaulted its request pool
   to 4 threads while pinned to 3 cores, on top of 6 job workers. Oversubscription
   thrash — heat with no throughput.

Cooling was already exhausted and is not the lever: fan at `cur_state=4/4`,
**9,724 rpm**, pwm 250/255.

### Two things that were ruled OUT

- **Moving photos to the NVMe would not have helped.** `iowait` measured 0–1%, blocked
  processes 0, D-state 0 — nothing waits on disk; the load is pure compute. The tiering
  that matters is already done (thumbs 4.5 G and Postgres 430 M on NVMe, 105 G of
  originals on the pool). Also: do **not** move `photos/upload/` to the NVMe on its own.
  Immich lands assets there then *moves* them into `library/`; same filesystem is a cheap
  rename, split across devices turns every import into a full cross-device copy — the
  same trap as the *arr hardlink issue.
- **zram was not a heat source, and trimming `mem_limit`s would do nothing.** zram was
  96% full (1.9 of 2.0 GiB) but *parked*, not churning: steady-state `si/so` of 40/0 and
  64/72 KB/s, with `vm.swappiness` already at 10. Those limits are ceilings, not
  reservations, and actual RSS is far below them. The real risk there is **OOM, not
  temperature** — only ~135 MiB of swap headroom, on a box where `immich_server` has
  OOM-looped 24x at a tighter limit. The guard warns on it instead (alerts below
  192 MiB free, re-arms above 384 MiB), so expect one ntfy on install: 135 MiB is
  already under the line, which is the point.

## Round 2: hold a temperature, not a core budget

The first version of this picked a **throughput** (2.5 Immich cores) and hoped the temperature
would be acceptable. It wasn't — it settled at ~84 °C, and worse, the governor ended up pinned
at its floors with no authority left. A control loop sitting on its limits is not a stable
system; it is one that is out of range. Two things were wrong:

- **The 2.5-core ceiling assumed an idle host.** Measured baseline is **~1.3 cores** before
  Immich gets any: `tailscaled` ~0.44 (WireGuard crypto for the phone upload), `mergerfs` ~0.20
  (FUSE overhead on the pool), misc host ~0.65.
- **The floors were too high** (ML 0.5 / server 0.75 = 1.25 cores minimum), so even fully
  trimmed, Immich plus baseline still exceeded what the case can dissipate.

So it is inverted now: **`HOT` in `/etc/immich-thermal.conf` is a temperature target, and the
guard finds whatever throughput fits under it.** Default 76 °C — about 9 °C of headroom under
the 85 °C soft limit, which is what "stable" should mean: room for a hot day, and the fan off
its 9,700 rpm ceiling. Floors dropped to ML 0.25 / server 0.50, so the loop can walk Immich all
the way down to **0.75 cores** if it has to. Lowering `HOT` makes the backfill slower; it never
makes it fail.

One knob:

```bash
sudo sed -i 's/^HOT=.*/HOT=72.0/' /etc/immich-thermal.conf   # cooler, slower
```

`install.sh` will not overwrite an existing conf — new defaults land at `.conf.dist`.

## What this installs

- `docker-compose.override.yml` — hard `cpus` quotas plus explicit `MACHINE_LEARNING_*`
  thread caps. **This is what fixes the known "live-only, reverts on any container
  recreate" gap**: the quotas now live in the file, and the file holds the *conservative
  day* values so any `compose up -d` lands somewhere safe.
- `immich-thermal.conf` — the tunables, `HOT` above all. Installed to `/etc/`.
- `immich-cpu-profile day|night|status` — sets the starting **ceiling** and which service the
  guard protects. Total ceiling 1.8 cores in both profiles; only the split moves. Day favours
  `immich_server` (thumbnails feed every other queue and are what the UI waits on); night
  favours ML (grind the backlog while nobody is looking). These are ceilings, not allocations —
  the guard trims below them freely.
- `immich-thermal-guard` — every 2 min: trims 0.25 cores after two consecutive samples above
  `HOT`, restores toward the ceiling below `COOL`, floors at ML 0.25 / server 0.50. A fixed
  quota can't be stable here — the same load that sits at 80 C in a cool room sits at 87 C in
  August, and `tailscaled`'s share depends on whether a phone happens to be uploading through
  the tunnel. If it bottoms out and is *still* hot with the fan maxed, that is a cooling or
  external-load problem, and it pushes an ntfy alert via the existing `ntfy-send`.
- `tests/guard-test.sh` — exercises the control loop off-box against a stubbed
  `docker`: hysteresis, both floors, per-profile restore order, alert latching, and
  "stack is down" being a clean no-op, `HOT` actually being read from the conf, and the
  governor being able to reach 0.75 cores total, and budget handover when one service is
  stopped. **35 assertions, all passing as committed.**
  Run it on the Mac before shipping any change to the guard.
- Timers: guard every 2 min, night at **23:30**, day at 08:00. Night starts at 23:30 and
  not 01:00 on purpose: Immich's own nightly job (`missingThumbnails` + `clusterNewFaces` +
  `generateMemories`) fires at 00:00, and that cascade is what set off this backfill — so be
  in night mode before it starts, not an hour into it. The day timer is
  `Persistent=true` so any downtime lands back in the safe profile; the night timer is
  deliberately **not**, so booting at 10:00 cannot drop you into night mode mid-use.

## Install

```bash
rsync -a ~/Documents/personalDev/homeserver/thermal/ pihome:~/thermal/
ssh pihome
cd ~/thermal && sudo ./install.sh --dry-run    # look first
cd ~/thermal && sudo ./install.sh
```

Step 5 recreates the two Immich containers — the thread caps are env vars and env only
applies on recreate, which `docker update` cannot do. Brief downtime; in-flight jobs are
re-queued by BullMQ, not lost.

To validate the guard itself first, on the Mac:

```bash
cd ~/Documents/personalDev/homeserver/thermal && bash tests/guard-test.sh
```

Then, after ~5 minutes:

```bash
immich-cpu-profile status
journalctl -t immich-thermal-guard -n 20
```

Settling is slow **by design**: 0.25 cores at most every 2 min, so from the starting ceiling
it takes ~10–15 min to find its level. Expect the SoC to land just under `HOT` and `throttled`
to stop reporting bit 2 (`0x4`). The historical bits (`0xf0000`) are sticky since boot and will
not clear until a reboot.

### Two free wins that are not in this installer

- **Point the iOS Immich app at `http://<pi-lan-ip>:2283` while at home.** Measured: the
  phone was uploading at **76.5 Mbit/s through the Tailscale tunnel**, costing `tailscaled`
  **0.44 cores** of userspace WireGuard crypto. 76 Mbit/s is LAN speed, so it is on the LAN and
  tunnelling anyway. That is 12% of the box back for a phone setting.
- **Turn OCR off** if you don't search photos by text (Admin → Machine Learning → OCR). It is
  already the lightest model, so off/on is the only lever — and it will otherwise queue a job
  for every one of 18,696 assets.

## Turning ML off for a while

**⚠ ORDER IS NOT OPTIONAL, and getting it wrong is much worse than doing nothing.** Measured on
2026-09-17: stopping the container while the features were still enabled in settings produced
**~450 failed ML connections per second** — 27,000 log lines/minute and `immich_server` at 94%
CPU, all of it churn. That costs far more than the ~3-4 °C the stop was meant to save.

1. **Admin → Machine Learning → disable** the features (Smart Search / Facial Recognition / OCR).
   This is a browser action; it cannot be scripted from here without an API key.
2. Confirm it took: the config should no longer be empty —
   `docker exec immich_postgres psql -U postgres -d immich -t -c "select value->'machineLearning' from system_metadata where key='system-config';"`
3. Only then `docker stop immich_machine_learning`, to reclaim its ~870 MB.

To undo, reverse it: start the container, then re-enable in settings.

**If you are not going to do step 1, leave the container running.** The guard pins ML to its
0.25-core floor anyway, so an idle-ish ML container is cheap and generates no churn. Take the
headroom from the phone-on-LAN and preview-size levers instead; both are larger and have no
failure mode.

The guard detects a stopped service and **hands its share of the budget to the other one**, so
`thumbnailGeneration` gets the full 1.8 cores instead of being starved at its floor while the
governor wastes adjustments on a dead container. Restart it and the split returns on the next
tick. Measured worth of turning ML off: **~3-4 °C** (ML was 0.25 cores, and the box runs about
15 °C per core in this regime) — the real wins are stopping ~44,000 future ML jobs from being
enqueued across 21,910 assets, freeing the RAM, and letting thumbnails finish.

Note: if `buffalo_s` is in your future, running face ML now with `buffalo_l` is work that gets
invalidated and re-run, so deferring it costs nothing.

## Two steps left for you, on purpose

**1. Switch the face model to `buffalo_s`.** The single biggest ML win —
`buffalo_l` is 183 M of the model cache and face work is the dominant queue (358 + 26
waiting). Not scripted, because changing it **invalidates every existing face embedding**
and forces a full re-scan. That should be a deliberate click, and now is the cheapest
moment to make it, mid-backfill.

Admin → Settings → Machine Learning → Facial Recognition → model `buffalo_s`, then
re-run Face Detection (All). Confirm the exact options in the dropdown.

**2. Decide on OCR.** `PP-OCRv5_mobile` is *already* the lightest OCR model — there is no
lighter one to pick, so your only lever is off/on. It is roughly a third of ML load for
167 queued jobs. If you do not search photos by the text inside them, turn it off:
Admin → Settings → Machine Learning → OCR.

Not worth touching: **CLIP `ViT-B-32__openai`** is already the lightest useful CLIP (the
alternatives are bigger), `smartSearch` is idle at 0/0, and it self-unloads after 300 s.

## Also still open (pre-existing, unrelated to heat)

Three real undervoltage events since boot — `[46885.8]`, `[75421.6]`, `[98076.7]`
`Undervoltage detected!`. This is the official-27 W-PSU item, not something this fixes.

## Rollback

```bash
sudo ~/thermal/install.sh --uninstall   # removes timers/scripts, restores prior override
cd /opt/stack/immich && docker compose up -d
```
