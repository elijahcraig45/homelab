# Docker daemon config

`daemon.json` is installed at `/etc/docker/daemon.json` on the homelab.

It sets fixed DNS servers (the router, then Cloudflare) for every container. Without it, Docker copies the host's
`/etc/resolv.conf` when each container starts. After the 2026-10-28 power blip, Docker started all containers about two
minutes before DHCP had written that file. 16 containers got "NO EXTERNAL NAMESERVERS DEFINED" and could not resolve
anything outside the box for 7 days: Prowlarr indexers, Sonarr/Radarr/Lidarr RSS and Seerr all failed, while every
web check stayed green. With fixed servers, lookups fail only until the router is back, then recover on their own.

Install, or reinstall after a rebuild (this restarts every container):

    sudo install -m 644 docker/daemon.json /etc/docker/daemon.json
    sudo dockerd --validate --config-file /etc/docker/daemon.json
    sudo systemctl restart docker

`alerting/pihome-health` checks DNS from inside the containers every 2 minutes, and the nightly backup carries this file
in host-config.tar.gz.

## Compose projects

`stack/docker-compose.yml` is `/opt/stack/docker-compose.yml` (the media stack, 15 containers) and `immich/` is
`/opt/stack/immich` (Immich's upstream compose file, untouched, plus our `docker-compose.override.yml`). Their `.env`
files hold per-host values and the Immich DB password, so they stay on the host only. The Ansible `docker` role
installs these files and checks that the running containers match them (`ansible/README.md`).
