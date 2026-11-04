# demeter

A self-hosted media server. You request a movie or show, and it gets found, downloaded over a VPN, renamed, filed into the library and is ready to stream in Jellyfin.

```

Seerr requests ─▶ Radarr / Sonarr ─▶ Prowlarr ─▶ qBittorrent ─▶ /data ─▶ Jellyfin
                                    (indexers)   (over Proton VPN)
```

`docker-compose.yml` is the source of truth for how the stack is wired.

## Services

| Service | Purpose | Network | Port |
|---|---|---|---|
| [gluetun](https://github.com/qdm12/gluetun) | Proton VPN (WireGuard) with port forwarding | own | publishes 8080, 9696 |
| [qBittorrent](https://www.qbittorrent.org/) | Torrent client | gluetun's namespace | 8080 |
| [Prowlarr](https://prowlarr.com/) | Indexer manager, syncs indexers to Sonarr/Radarr | gluetun's namespace | 9696 |
| [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr) | Gets past Cloudflare for protected indexers | gluetun's namespace | not published |
| [Sonarr](https://sonarr.tv/) | TV | bridge | 8989 |
| [Radarr](https://radarr.video/) | Movies | bridge | 7878 |
| [Jellyfin](https://jellyfin.org/) | Media server, Intel QSV/VAAPI transcoding | bridge | 8096 |
| [Seerr](https://github.com/seerr-team/seerr) | Request UI (merged Overseerr/Jellyseerr) | bridge | 5055 |

qBittorrent, Prowlarr and FlareSolverr use `network_mode: service:gluetun`, so all of their traffic goes through the VPN or doesn't go out at all. Prowlarr is behind the VPN on purpose, because UK ISPs block several public trackers.

### Addressing between containers

- Use container names, not `localhost`: `sonarr:8989`, `radarr:7878`, `jellyfin:8096`.
- To reach anything inside the VPN namespace, use `gluetun`. qBittorrent is `gluetun:8080` and Prowlarr is `gluetun:9696`.
- The one exception is Prowlarr → FlareSolverr, which is `http://localhost:8191/` because the two share a network namespace.

## Host

- Ubuntu Server on a small Intel box (UHD 630 iGPU, `/dev/dri` passed through to Jellyfin).
- OS, Docker and `config/` live on the boot SSD. Media lives on a separate NVMe mounted at `/data`.
- Remote access is only over [Tailscale](https://tailscale.com/). Nothing is port-forwarded on the router.

## Setup

### 1. Storage

All of `/data` must be on **one filesystem** so that hardlinks work. If it isn't, every import becomes a full copy.

```bash
sudo mkfs.ext4 -m 1 /dev/nvme0n1p1
# /etc/fstab
UUID=<uuid>  /data  ext4  defaults,noatime,nofail  0  2

sudo mkdir -p /data/{torrents,media}/{tv,movies}
sudo chown -R 1000:1000 /data
```

Layout ([TRaSH Guides](https://trash-guides.info/File-and-Folder-Structure/) style):

```
/data/torrents/{tv,movies}   qBittorrent downloads (one folder per category)
/data/media/{tv,movies}      Sonarr/Radarr libraries; Jellyfin mounts /data/media read-only
```

Stop Docker from starting (and filling the SSD) when the NVMe isn't mounted:

```bash
sudo systemctl edit docker.service
# [Unit]
# RequiresMountsFor=/data
```

A seeding torrent and its library copy are hardlinks to the same file, so they don't use double the space. Use `df` to check usage. Adding up `du` across both folders counts those files twice.

### 2. Secrets

```bash
cp env.example .env
```

Fill in `PUID`/`PGID`, `TZ`, and the Proton WireGuard private key. To get the key, go to account.protonvpn.com → Downloads → WireGuard configuration, enable **NAT-PMP (Port Forwarding)**, pick a P2P server, and copy the `PrivateKey` line. Port forwarding needs a paid Proton plan.

`.env` and `config/` are gitignored. Never commit them, because they contain API keys, databases and password hashes.

### 3. Start

```bash
sudo install -d -o 1000 -g 1000 config/seerr   # Seerr runs as uid 1000
docker compose up -d
```

If gluetun is ever recreated, recreate everything that uses its network namespace too:

```bash
docker compose up -d --force-recreate qbittorrent prowlarr flaresolverr
```

### 4. App configuration

**qBittorrent** (`:8080`)
- Default Torrent Management Mode: **Automatic**.
- Default save path `/data/torrents`. Categories: `tv` → `/data/torrents/tv` and `movies` → `/data/torrents/movies`.
- WebUI → enable **Bypass authentication for clients on localhost**. gluetun needs this to push Proton's rotating forwarded port into qBittorrent (`VPN_PORT_FORWARDING_UP_COMMAND`).
- Seeding limits: after the ratio/time limit, choose "Remove torrent and its files". This is safe because the library copy is a hardlink.

**Prowlarr** (`:9696`)
- Settings → Indexers: add FlareSolverr as an indexer proxy at `http://localhost:8191/` with tag `flare`. Put that tag on Cloudflare-protected indexers.
- Settings → Apps: add Sonarr (`http://sonarr:8989`) and Radarr (`http://radarr:7878`) with **Full Sync**. Set the Prowlarr Server to `http://gluetun:9696`.
- Only manage indexers here. Don't add them directly in Sonarr or Radarr.

**Sonarr / Radarr**
- Root folders: `/data/media/tv` and `/data/media/movies`. Turn on hardlinks and renaming.
- Download client: qBittorrent at `gluetun:8080`, with category `tv` or `movies`.
- Connect → Jellyfin (`jellyfin:8096`) with Update Library.
- Connect → Telegram for health issues and health restored (set the same up in Prowlarr).
- Radarr: add a Trakt watchlist import list. TV goes through Seerr so you can choose which seasons to get.

**Jellyfin** (`:8096`)
- Libraries: Movies at `/data/media/movies` and Shows at `/data/media/tv`.
- Enable hardware transcoding (QSV/VAAPI) on `/dev/dri`.
- Networking → LAN networks: add `100.64.0.0/10` so Tailscale clients are treated as local.
- Auto-discovery doesn't work through the Docker bridge, so add the server in clients by hand at `http://<tailscale-name>:8096`.

**Seerr** (`:5055`)
- Connect it to Jellyfin, Sonarr and Radarr, then import users under Users → Import Jellyfin Users.

## Backups

`scripts/backup.sh` uses [restic](https://restic.net/) to back up `config/` and `.env` to S3 every night. Media isn't backed up because it can be downloaded again.

What the script does:
1. Stops the stack so the SQLite databases are copied in a consistent state.
2. Backs up `config/` and `.env`, leaving out Jellyfin's cache and transcodes and the app logs and backups.
3. Restarts the stack.
4. Runs `forget --prune` (keeping 7 daily, 4 weekly and 6 monthly snapshots) and checks 5% of the data.

Setup:
1. Create a bucket and an IAM user limited to it with `policies/restic-s3-policy.json` (replace `BUCKET_NAME`).
2. Create `/etc/media-backup.env` with the AWS credentials, `RESTIC_REPOSITORY` and `RESTIC_PASSWORD_FILE`, and `/etc/media-backup.restic-pass`. Both should be owned by root with mode `0600`. Keep a copy of the restic password in a password manager, because without it the backups can't be restored.
3. Run `sudo restic init` once with that environment loaded.
4. Add it to root's crontab:
   ```
   0 4 * * * /path/to/demeter/scripts/backup.sh >> /var/log/media-backup.log 2>&1
   ```

Restore:

```bash
sudo -i
set -a; source /etc/media-backup.env; set +a
restic snapshots --tag media-stack
cd /path/to/demeter && docker compose down
restic restore latest --tag media-stack --target /path/to/demeter
docker compose up -d
```

## Troubleshooting

- **A request was added but nothing downloads.** In Sonarr/Radarr, check System → Status for indexers that were disabled after failures. Testing an indexer re-enables it. Then run an Interactive Search and read the rejection reasons. Prowlarr's History shows whether the *arrs are sending queries at all.
- **qBittorrent torrents are "Errored" or show "Permission denied".** The torrent management mode is probably Manual, so files went to the unmounted `/downloads`. Switch the default to Automatic.
- **gluetun logs "up command: Connection refused" at startup.** qBittorrent hasn't started yet. gluetun retries, so this is harmless.
- **Locked out of qBittorrent.** Reset the password through the localhost-bypass API with `docker exec qbittorrent curl ... /api/v2/app/setPreferences`. Or stop the container and delete `WebUI\Password_PBKDF2` from `config/qbittorrent/qBittorrent/qBittorrent.conf`.
- **Moving `/data` to a new disk.** Stop the stack, run `rsync -aHAX` on the whole tree (`-H` keeps the hardlinks), swap the mount, then start the stack.

## Roadmap

- [Recyclarr](https://recyclarr.dev/) to manage TRaSH quality profiles and custom formats as code.
- Caddy with DNS-01 to serve HTTPS subdomains over the tailnet.
- Automatic cleanup of watched media (Trakt-based, or [Janitorr](https://github.com/Schaka/janitorr)).
