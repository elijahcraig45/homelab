# homelab as code (Ansible)

One playbook describes the whole homelab (Dell OptiPlex 7070 Micro, Debian 13): OS packages and repos, firewall,
disks and the mergerfs pool, Docker and both compose projects (about 20 containers), Samba, `tailscale serve`,
alerting, backups, the launcher and status page, the picture frame, coursework Jupyter, the ML lab, the production
prediction pipeline (13 jobs), and a study app.

## Run it

```bash
cd ansible
uv venv .venv && uv pip install --python .venv/bin/python -r requirements.txt   # once
cp -n examples/host_vars.example.yml host_vars/homelab.yml                      # first time only; -n never overwrites

.venv/bin/ansible-playbook site.yml --check --diff     # what would change; touches nothing
.venv/bin/ansible-playbook site.yml --diff             # apply
.venv/bin/ansible-playbook site.yml --check --tags samba,backup   # one area
```

It runs from a laptop over the `homelab` SSH alias and expects sibling checkouts of the ML lab
([hanks_tank_lab](https://github.com/elijahcraig45/hanks_tank_lab), checked out as `mllab`) and the study app
(`ml4t`, private). Those repos stay the source of truth for their own units and host scripts; this playbook installs
them as they are.

## Rules

- **Check before apply.** A real run happens only after `--check --diff` shows the expected changes and nothing else.
- **Secrets are never in git.** `host_vars/homelab.yml` → `secret_files` lists every secret or per-host file (keys,
  `.env` files, tokens). The `secrets` role only checks that each one exists with the right owner and mode, never
  reads it, and names the script that creates it when it is missing.
- **The pipeline's mode files are off limits.** `/etc/pipeline/jobs.d/*` (off | dry | live) is the pipeline's
  single-writer safety model and only `pipeline-ctl set` changes it. A rebuilt host has none, so every job starts
  `off` and a rebuild cannot write to BigQuery.
- **Nothing restarts the world implicitly.** A changed `daemon.json` prints a notice instead of restarting dockerd.
  Compose runs with `pull: never`, so a run never upgrades an image. fstab entries are written, never remounted.
- **Apps install themselves.** The ML lab, the pipeline runtime and the study app have their own installers
  (`mllab/host/install.sh`, `mllab/host/pipeline/install.sh --release --ref <sha>`, `ml4t/host/install.sh`).
  These roles check that the install is there, then manage its units.

## Layout

| Role | What it covers | Sources |
|---|---|---|
| base | Docker + Tailscale apt repos, packages, admin user, SSH (hardening behind a switch), sysctl, LAN interface | `roles/base` |
| firewall | ufw defaults, LAN SSH/SMB, tailnet, container access to status/frame | host_vars |
| storage | data disks + mergerfs pool in fstab, smartd | host_vars, `roles/storage/files` |
| docker | `daemon.json`, media stack + Immich compose projects | `docker/` |
| samba | `files` and `timemachine` shares; restarts smbd if it is not bound to the LAN address | `roles/samba/files` |
| tailscale | tailscaled, GRO tuning unit, the full `tailscale serve` port map | host_vars |
| alerting | `pihome-health` probe, ntfy helpers | `alerting/` |
| backup | `backup-run` + timer, `.backup` / `.nobackup` markers | `backup/` |
| launcher | launcher page, its Caddyfile, live status page | `launcher/`, `status/` |
| picture_frame | slideshow, dimming, sync | `picture-frame/` |
| jupyter | coursework JupyterLab | `roles/jupyter/files` |
| mllab | ML lab units and host scripts | `../../mllab/host` |
| pipeline | 22 pipeline units (13 job timers, pregame, broker) | `../../mllab/host/pipeline/units` |
| ml4t | study app units | `../../ml4t/host` |
| secrets | existence, owner and mode of every secret file | host_vars |

In the public copy, `docker/stack/` (the media compose file), `launcher/`, `status/` and `picture-frame/` are not
included, and the real `host_vars/homelab.yml` is replaced by `examples/host_vars.example.yml`.

## Verified

2026-11-11, against the live host:

- `--check --diff` on the baseline: **77 tasks, 0 unexpected changes.** The one difference was a launcher card
  committed in the repo but never deployed.
- The check catches drift: an injected firewall rule, a changed `tailscale serve` target and a changed compose
  file were each reported as a change. (In check mode the compose task compares running containers with the
  compose file *on the host*; the file copy step before it catches repo-vs-host drift.)

## Found while writing it

- **LAN SMB had been down since boot** because `allow-hotplug eno1` lets network-online fire before DHCP, so smbd
  bound a link-local address. The same race left containers without DNS after a power blip. Fixed here
  (`auto eno1`, plus an smbd rebind check).

## Not managed yet

- Debian's own base install (partitioning, locale, `/etc/hosts`, the root/boot/swap fstab lines).
- The contents of `/opt/stack/.env` and the other secret files (by design).
- Container image versions (`:latest` tags; pinning is a separate step) and Uptime Kuma's monitors
  (they live in its SQLite DB).
- The disaster-recovery drill (build a throwaway VM, run this, restore from backup, time it) is still to do.
