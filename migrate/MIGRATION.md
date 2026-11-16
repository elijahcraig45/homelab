# pihome -> OptiPlex 7070 Micro

Target: **Dell OptiPlex 7070 Micro, i5-9500T, 16 GB, 256 GB NVMe** (renewed, Win 11 Pro to be wiped).
Source: Raspberry Pi 5, Debian 13 trixie aarch64, 17 containers, 30 TB mergerfs pool over USB.

## How this differs from the 3060 SFF we scoped

**Better:**
- **i5-9500T > i5-8400T** — same 6C/6T and same UHD 630, but 2.2/3.7 GHz vs 1.7/3.3. ~15-20% faster,
  and 9th gen rather than 8th.
- **Lower idle power.** A Micro chassis with a T-series chip draws less than an SFF — better for 24/7.
- Smaller and quieter.

**Worse:**
- **No PCIe slot, no 3.5" bay.** The 2-bay USB enclosure is now permanent, and the deferred SnapRAID
  third drive will need a 3-bay enclosure rather than going internal. No 10GbE path either
  (irrelevant at 20 Mbit up / gigabit LAN). The 7070 Micro does take one 2.5" SATA drive.
- **256 GB instead of 1 TB.**

**The 256 GB is fine, despite first appearances.** pihome uses **25 GB of 457** today:
OS ~10 GB + docker images 11.2 GB + appdata 5.8 GB + volumes 0.8 GB. Immich thumbs are 4.5 GB at
21,910 assets, so even a 100k-asset library lands around 20 GB. That leaves ~200 GB spare.
Optional if you want headroom anyway: the Pi's WD Blue SN5100 **500 GB NVMe can move into the 7070**
(one M.2 2280 slot) and the Pi falls back to the microSD sealed in its case, which is fine for
picture-frame duty.

## Day before

```bash
ssh pihome 'cd ~/thermal && :'          # nothing to do, just a reminder you have shell
scp ~/Documents/personalDev/homeserver/migrate/preflight.sh pihome:~/
ssh pihome 'sudo ~/preflight.sh'
```

Collects into `/mnt/appdata/_migration/`: an Immich `pg_dumpall`, both compose stacks, host configs,
host scripts, systemd units, and an inventory. It starts `immich_postgres` briefly for the dump and
stops it again. Re-runnable.

**Optional:** a DHCP reservation for the 7070's MAC -> <pi-lan-ip>. Nice for tidiness, but
see gotcha 1 — this is NOT the DNS emergency the earlier drafts claimed.

## Cutover

1. **Install Debian 13 (trixie) amd64.** Same release as the Pi, so every config file ports verbatim.
   Wipe Windows — the Pro licence is a digital entitlement tied to the board, recoverable later if
   you ever want it. Installer answers that matter (verified against pihome 2026-09-19):
   - **Name the first user `pi`.** Debian gives the first user uid 1000/gid 1000, which is exactly
     what the appdata expects: 74 of 91 top-level appdata entries are `1000:1000`, and
     `/opt/stack/.env` pins `PUID=1000 PGID=1000`. It also keeps `ssh pihome`, `valid users = pi`
     and `force user = pi` in smb.conf working verbatim. Any other name still lands on uid 1000,
     but every doc and config then reads wrong.
   - **Hostname `pihome`**, matching the Caddy site, Kuma monitors and the Samba config.
   - **tasksel: "SSH server" + "standard system utilities" ONLY.** No desktop — this box is headless.
   - Guided partitioning, entire disk. Secure Boot can stay enabled; the official netinst is signed.
2. **Base packages:** `docker.io docker-compose-plugin mergerfs samba smartmontools ethtool rsync`,
   plus Tailscale from its own repo.
3. **Give it <pi-lan-ip>** (reservation, or static). Verify before going further.
4. **Pull appdata across** while the Pi is still up and serving. **Root on BOTH ends —
   see gotcha 9; a plain user rsync silently skips ~1,764 files:**
   ```bash
   sudo rsync -aHAX --info=progress2 --rsync-path="sudo rsync" \
       pihome:/mnt/appdata/ /mnt/appdata/
   ```
   ~6.3 GB. Repeat just before cutover to catch deltas.
5. **Restore host bits** from `/mnt/appdata/_migration/`:
   - `etc/smb.conf` -> `/etc/samba/`, `etc/caddy-pihome.Caddyfile` -> `/etc/`,
     `etc/www-pihome` -> `/var/www/pihome`, `etc/smartd.conf`, `etc/ntfy-alert.conf` (root 0600)
   - `bin/*` -> `/usr/local/bin/` (755)
   - `units/*` -> `/etc/systemd/system/`, then `daemon-reload` and enable
   - `stack/` -> `/opt/stack/`
   - Append the three pool lines from `etc/fstab` to the new `/etc/fstab`
6. **Stop Immich-adjacent writers on the Pi, move the enclosure.**
   ```bash
   ssh pihome 'cd /opt/stack && docker compose stop && sudo umount /mnt/storage /mnt/disk1 /mnt/disk2'
   ```
   Unplug the USB enclosure, plug into the 7070, `sudo mount -a`, confirm `/mnt/storage` shows ~30 TB.
   The filesystems are **4096-byte-block ext4** and fstab is UUID-based, so they mount on x86 as-is.
7. **Bring the main stack up:** `cd /opt/stack && docker compose up -d`. Images pull as amd64
   automatically. Check Caddy, AdGuard, Jellyfin, the *arrs.
8. **Immich, when you want it back:**
   ```bash
   cd /opt/stack/immich && docker compose up -d database redis
   zcat /mnt/appdata/_migration/immich-pgdumpall-latest.sql.gz | docker exec -i immich_postgres psql -U postgres
   docker compose up -d
   ```
9. **Tailscale:** `tailscale up --advertise-routes=<lan-cidr>`, approve the route in the admin
   console, then remove the old `pihome` node.

## Gotchas, in the order they will bite

1. **CORRECTED 2026-09-19 — the "DNS breaks for the whole house" scare is FALSE.** AdGuard does
   bind `0.0.0.0:53` host-networked, but **`ufw` never opens 53 to the LAN**. The LAN rules are
   only `22/tcp` and `445/tcp` from `<lan-cidr>`, plus anything on `tailscale0`. So no LAN
   device can use it as a resolver even if you pointed one at it, and none do: `clients.persistent`
   is `[]`, there is no `querylog.json`, `stats.db` has not been written since boot, and a `dig`
   from a LAN host times out. **`<pi-lan-ip>` is a dynamic lease and changing it costs you
   almost nothing.** Reserve it for tidiness (old Pi MAC `2c:cf:67:28:3c:65`), but it is not a
   cutover blocker and needs no DNS-outage workaround.

   **The Tailscale identity matters more than the IP, but less than first thought.** Corrected
   after inspection: the Caddyfile contains **no hostnames at all** — it is a bare `:80` block, and
   TLS is terminated by `tailscale serve` (`https://<node>.<tailnet>.ts.net -> 127.0.0.1:8090`,
   plus `:3001` for Kuma and tcp `:445` for SMB). That mapping is Tailscale state and is recreated
   per node, so a renamed host does NOT break site matching or certs. The 38 `pihome.<tailnet>`
   references are all in `etc/www-pihome/index.html` (22) and its `.bak` (22) — links on the
   `/apps` launcher page. Renaming the host costs one find-and-replace there, plus re-running the
   three `tailscale serve` mappings. **Still delete the old tailnet node first**, or the new one
   registers as `<name>-1` and the serve URLs carry that suffix.
2. **Never rsync the Immich Postgres data directory.** PG data dirs are not portable across
   architectures. That is what the `pg_dumpall` is for. Stack is PG 14.19 + vectorchord0.4.3 +
   pgvectors0.2.0; the image is pinned **by digest** in the compose file. **Verified 2026-09-19:
   that digest is a multi-arch manifest list and does include `amd64`, so no tag fallback is
   needed** — `docker manifest inspect` on the pinned digest returns amd64, arm64 and unknown.
3. **`cpu-governor.service` will not work as-is.** It writes `schedutil`, which does not exist under
   x86 `intel_pstate`. Either drop the unit or change it to `powersave` (which is the efficient,
   correct default on intel_pstate — not a performance cut).
4. **`tailscale-gro.service` hardcodes `eth0`.** The Dell NIC will be `eno1` or similar. Update the
   `ethtool` line or the unit fails silently and Tailscale throughput suffers.
5. **Do NOT migrate the thermal stack.** `immich-thermal-guard`, `immich-cpu-profile`, the day/night
   timers and `/etc/immich-thermal.conf` exist only because the Pi's cooling runs ~4x worse than
   spec. The 7070 does not need them and they would only get in the way. `preflight.sh` deliberately
   does not collect the units (it does keep the scripts, for reference).
6. **Do NOT migrate the `picture-frame-*` units.** Those moved to the Pi 3 (`pidesk`) on 2026-09-17;
   the copies on pihome are vestigial.
7. **Re-add Immich to monitoring** once it is running again: the four `immich_*` names go back into
   `CONTAINERS` in `/usr/local/bin/pihome-health`, and Kuma monitor id 2 "Immich" back to `active=1`.
   Both were muted when Immich was stopped.
8. **Check the renewed hardware on day one:** `smartctl -a` on the 256 GB NVMe for wear, and expect
   fan/thermal-paste refresh to be the eventual wear items on any refurb.

10. **Samba passwords do NOT migrate.** `preflight.sh` collects `smb.conf` but not
    `/var/lib/samba/private/passdb.tdb` (1.6 MB, root 0600, currently holding one account: `pi`).
    Rather than copy a tdb between machines, just re-set it on the new box after installing samba:
    `sudo smbpasswd -a pi`. Until you do, the `files` and `timemachine` shares will reject every
    login — `security = user` with `map to guest = never`, so there is no guest fallback.

9. **The appdata rsync MUST run as root on both ends.** Verified 2026-09-19: 1,764 files
   under `/mnt/appdata` are not world-readable, including the whole `_migration/etc/` bundle
   (root 0700 — `preflight.sh` ends with `chmod -R go-rwx`), most of `uptime-kuma`, and parts
   of the Immich appdata. rsync over SSH as `pi` skips them **without failing**, so step 5 then
   cannot find `smb.conf`, the Caddyfile, `fstab`, `ntfy-alert.conf` or `smartd.conf`, and Kuma
   comes up with no history. Use `sudo` locally (to write preserved ownership) plus
   `--rsync-path="sudo rsync"` remotely. `pi` has NOPASSWD sudo, so this needs no tty.

11. **`preflight.sh` had four collection gaps — fixed 2026-09-19, but re-run it if your bundle
    predates that.** It omitted (a) `/etc/pihome-health.conf`, which holds the Uptime Kuma push
    token, so monitoring restores silently dead; (b) `/usr/local/bin/pihome-status`, even though
    `pihome-status.service` *was* collected, leaving the unit pointing at a missing binary;
    (c) `backup-mark` and `backup-status`. Deliberately still not collected: `frame-*` (Pi 3),
    and `burnin-*`/`powertest`/`scratch-guard` (one-off Pi build tools).

12. **Do NOT blind-sed the hostname.** Two `pihome` strings are not hostnames and renaming them
    breaks things silently: `BUCKET="gcs:<backup-bucket>"` in `backup-run` is a **GCS
    bucket name**, and `pihome-4f6820c4b286b307` in `ntfy-alert.conf` is a **secret ntfy topic**
    your phone (and the Pi 3) is subscribed to. The script, unit and `/var/lib` names are internal
    identifiers and are fine left as `pihome-*`.

13. **`smb.conf` hardcodes the Pi's IP and `bind interfaces only = yes`.** The global section
    carries `interfaces = 127.0.0.1/8 <pi-lan-ip>/24`. Restored verbatim onto a box at a
    different address, Samba binds an address it does not have and serves nothing on the LAN.
    Fixed 2026-09-19 by binding the NIC **by name** instead — `interfaces = 127.0.0.1/8 eno1` —
    which also survives any future IP change. (`server string` also said `pihome`.)

14. **The new box has NO firewall, and it has public IPv6.** Debian installs no `ufw`, and the
    Dell picks up globally routable v6 addresses, so SSH and Samba are internet-reachable the
    moment they start — nothing in the original runbook mentions this. pihome's rules, now
    mirrored onto homelab: default deny in / allow out / deny routed, plus `22/tcp` and `445/tcp`
    from `<lan-cidr>`, anything on `tailscale0` (v4 and v6), and `8098/tcp` from the docker
    bridge. Add the rules **before** `ufw --force enable` or you lock yourself out of the SSH
    session you are holding.

15. **Do not enable `pihome-health.timer` before Uptime Kuma is actually running.** Its
    `ExecStartPost` is `pihome-alert`, which is edge-triggered and pushes to ntfy — so an early
    enable sends "⚠ pihome problem" to your phone every two minutes for a box that is merely not
    finished yet. Enable it (and `backup-offsite.timer`, which needs `/mnt/storage`) after the
    stack is up.

## Rollback

The Pi is untouched until step 6, and even then recovery is: move the enclosure back, `mount -a`,
`docker compose up -d`. Keep the Pi intact until the 7070 has run clean for a few days.

## Afterwards

The freed Pi 5 should take over the picture frame from the Pi 3 — that box has 905 MiB of RAM and
cannot software-decode the 720p clips, so `include_videos` is currently forced off. Also revisit
**SnapRAID plus a third 16 TB drive**; with no internal bays it means a 3-bay USB enclosure, but a
drive failure currently means a restore over that same 20 Mbit uplink.

Once settled, do the two free streaming wins: set `RemoteClientBitrateLimit` (currently 0 = uncapped,
which is why you only get one remote stream) and turn on `AllowHevcEncoding`, both of which finally
pay off because UHD 630 does HEVC in hardware.
