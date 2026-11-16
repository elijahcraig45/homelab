# Homelab

One small box that runs my household's services and the production side of
[Hank's Tank](https://hankstank.com): a Dell OptiPlex 7070 Micro (i5-9500T, 16 GB) on Debian 13 with a 30 TB
mergerfs pool. It runs about 20 containers (photos with on-device ML, media, documents, DNS, monitoring), the
[ML lab](https://github.com/elijahcraig45/hanks_tank_lab), and the 13 production prediction jobs behind
hankstank.com. The whole host is described in Ansible, and nothing on it is exposed to the public internet: remote
access goes over Tailscale.

## What's here

| Path | What it is |
|---|---|
| [`ansible/`](ansible/) | The host as code: 15 roles from packages and firewall to storage, Docker, Samba, Tailscale, alerting, backups and the ML pipeline units. `--check --diff` against the live host shows zero unexpected changes and catches drift |
| [`alerting/`](alerting/) | `pihome-health`, a probe for what an HTTP monitor can't see: temperatures, SMART, pool space, container restart loops and DNS inside containers. It pushes to Uptime Kuma, which alerts my phone through ntfy. Plus an external watchdog for when the box itself is down |
| [`backup/`](backup/) | Nightly snapshots and an offsite copy to Google Cloud Storage with an append-only key: `rclone copy`, never `sync`, so nothing offsite is deleted because it vanished here. Preflight checks, exit codes and alerts |
| [`docker/`](docker/) | The Docker daemon config (fixed DNS for every container, and why) and the Immich compose project |
| [`migrate/`](migrate/) | The runbook for moving everything from a Raspberry Pi 5 (arm64) to the OptiPlex (x86) in one afternoon |
| [`thermal/`](thermal/) | From the Pi era: a controller that holds a temperature instead of a fixed CPU budget, with its own tests, and the evidence that the real fault was physical |
| [`scripts/publish_public.py`](scripts/publish_public.py) | How this public copy is made: export the committed tree, swap host details for placeholders, refuse if anything private is left |

## Incidents and what changed

- **Containers lost DNS for a week after a power blip.** Docker started every container before DHCP had written
  the host's `resolv.conf`, so 16 of 19 containers could resolve each other but nothing outside. Every HTTP check
  stayed green. Fix: fixed DNS servers in `daemon.json`, and a container-DNS check in the health probe.
- **The offsite backup silently failed for about 25 days** after the move to the OptiPlex: `rclone` wasn't
  installed, and the old script hid the failure for the biggest directories. `backup-run` was rewritten with a
  preflight, real exit codes and an alert on failure.
- **LAN file sharing was down since boot** because the network interface came up after the services that bind to
  it. Fixed in Ansible (`auto eno1` plus a rebind check). The same race caused the DNS incident.
- **The Raspberry Pi ran at 83 °C** under a load that should have run at 50–55 °C. Two rounds of CPU tuning didn't
  help, because a control loop pinned at its limits can't fix missing cooling. The measured thermal resistance was
  about 7x the spec, which pointed at the hardware. The same workload idles at 42 °C on the OptiPlex.

## Not done yet

- The nightly offsite run still reports errors for files that are edited in place, which the append-only key
  can't overwrite. The fix moves that protection to bucket versioning.
- No parity disk (SnapRAID is planned) and no UPS, so a disk failure or a power cut is a real risk.
- The disaster-recovery drill (rebuild on a throwaway VM from this repo and the backups, and time it) hasn't been
  run.

## What's not published

The media compose stack, the launcher page, the picture frame, build logs and the real host inventory (addresses,
disks, firewall details) stay private. [`ansible/examples/host_vars.example.yml`](ansible/examples/host_vars.example.yml)
shows the shape of the host settings.

## License

MIT
