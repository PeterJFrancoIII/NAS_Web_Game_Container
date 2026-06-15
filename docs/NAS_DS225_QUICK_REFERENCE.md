# MediaServer2 (DS225+) — Quick Reference

Last verified: **2026-06-14** via SSH (`MediaServer2` / `MediaServer2Local`).

---

## Identity

| Item | Value |
|------|-------|
| Model | Synology **DS225+** (`geminilake`, x86_64) |
| Hostname | **MediaServer2** |
| DSM | **7.3.2** (build **86009**) |
| Kernel | Linux **5.10.55+** |
| CPU | Intel Celeron J4125 (4 cores) |
| RAM | **18 GB** (~8.9 GB available typical) |
| Primary SSH user | **Viper117** (uid **1026**, gid **100** / `users`, group **administrators**) |
| Container UID/GID (qBit) | PUID **1026**, PGID **100** |
| Container UID/GID (RA2) | **1000:1000** |

---

## Network

| Interface | IP | Role |
|-----------|-----|------|
| `eth0` | **192.168.0.193/24** | Primary LAN |
| `eth1` | (down / link-local) | Secondary NIC unused |
| `tun1000` | 169.254.x/21 | Tailscale |
| Default gateway | **192.168.0.1** | Home router |

| Access | Value |
|--------|-------|
| LAN hostname | `MediaServer2.local` |
| DDNS | **peterjfrancoiii2.synology.me** |
| SSH port | **23921** (not 22) |
| Mac SSH alias (DDNS) | `MediaServer2` |
| Mac SSH alias (LAN) | `MediaServer2Local` |
| Mac SSH key | `~/.ssh/synology_ds225p_rsa` |

**Routing rule:** NAS host traffic stays on LAN. Only containers behind **Gluetun** use Surfshark VPN.

---

## Storage

| Volume | Size | Used | Mount | Role |
|--------|------|------|-------|------|
| `/volume1` | 8.8 TB | ~30% | `/volume1` | Legacy media (`/volume1/Media`) |
| `/volume2` | 8.8 TB | ~40% | `/volume2` | **Primary** apps, Docker, projects |

**Canonical user data root:** `/volume2/Data`

```
/volume2/Data
├── App_Development/ra2-lan-party/   # RA2 browser streaming project
├── docker/
│   ├── gluetun/                       # VPN client config
│   ├── qbittorrent/                 # qBit config (+ config/qBittorrent/)
│   └── qbit-gluetun/                # ACTIVE compose project
├── downloads/
│   └── qbittorrent/                 # qBit incomplete + watch folder
├── Games/
│   ├── 1 Packed - Compressed/       # qBit default save path
│   └── 2 Unpacked - Ready to Play/
├── Peter Documents/
├── Peter - Drive/
├── Programs/
├── Scripts/network/
└── _system_audits/
```

---

## Host automation

| Item | Path / detail |
|------|----------------|
| Passwordless sudo | `/etc/sudoers.d/Viper117-nopasswd` → `Viper117 ALL=(ALL) NOPASSWD: ALL` |
| Boot: TUN device for Gluetun | `/usr/local/etc/rc.d/S01qbit-gluetun-tun.sh` (creates `/dev/net/tun` before Docker) |

Re-apply sudo after DSM update if needed:
```bash
ssh -t MediaServer2 'cd /volume2/Data/App_Development/ra2-lan-party/project && sudo sh scripts/enable-passwordless-sudo.sh'
```

---

## Docker — running containers

| Container | Image | Status | Host ports |
|-----------|-------|--------|------------|
| **gluetun** | `qmcgaw/gluetun:latest` | healthy | **8080** (Web UI), **6881** tcp+udp |
| **qbittorrent** | `lscr.io/linuxserver/qbittorrent:latest` | up | *(via gluetun network)* |
| **ra2-player-1** | `ra2-lan-party:ultra` | healthy | **6081** → 6080 |
| **ra2-player-2** | `ra2-lan-party:ultra` | healthy | **6082** → 6080 |
| **kmia-arch-ingest** | `kmia-arch-ingest:latest` | up | *(no published ports)* |

Docker package: **ContainerManager 24.0.2**. Binary: `/usr/local/bin/docker`.

---

## VPN download stack (qBittorrent + Gluetun)

**Compose project (canonical):** `/volume2/Data/docker/qbit-gluetun`

```
Browser/LAN → NAS:8080 → gluetun → qbittorrent (network_mode: service:gluetun)
All torrent traffic → Surfshark OpenVPN (kill-switch via Gluetun firewall)
```

| Setting | Value |
|---------|-------|
| VPN provider | **Surfshark** (OpenVPN) |
| VPN exit (live) | **45.134.140.5** (US, varies on reconnect) |
| `SERVER_COUNTRIES` | United States |
| `FIREWALL` | on |
| `FIREWALL_INPUT_PORTS` | 8080, 6881 |
| `BLOCK_MALICIOUS` | off |
| `IPV6` | off |
| Restart policy | **unless-stopped** (both services) |
| Secrets | `/volume2/Data/docker/qbit-gluetun/.env` *(not in git)* |

**qBittorrent config:** `/volume2/Data/docker/qbittorrent/config/qBittorrent/qBittorrent.conf`

| Setting | Value |
|---------|-------|
| Web UI | `http://192.168.0.193:8080` (LAN only — **do not expose publicly**) |
| Web UI user | `Viper117` |
| Listen port | **6881** |
| Save path | `/Data/Games/1 Packed - Compressed` |
| Incomplete | `/downloads/incomplete/` |
| Watch folder | `/downloads/watch` (auto-add `.torrent` files) |
| Proxy | **Off** (`Proxy\Type=0`, all profiles false) |
| DHT / PeX | on |
| Queue | off |
| Global trackers | opentrackr, stealth.si, torrent.eu.org, exodus.desync.com, etc. |

**Operational commands:**
```bash
ssh MediaServer2Local
cd /volume2/Data/docker/qbit-gluetun
sudo docker compose up -d          # start
sudo docker compose restart       # restart both
sudo docker compose logs -f gluetun
sudo docker exec gluetun wget -qO- https://ipinfo.io/ip   # verify VPN IP
```

**Known limits:**
- Surfshark has **no port forwarding** → incoming peers on 6881 rarely work; use well-seeded torrents or `.torrent` files.
- Built-in qBit **Search tab fails** over VPN (`Forbidden` from index sites).
- Port **8080** is qBit Web UI — RA2 uses **6081/6082**, not 8080.

---

## RA2 browser streaming (production)

**Project root:** `/volume2/Data/App_Development/ra2-lan-party`

```
ra2-lan-party/
├── project/          # compose, scripts, container build (sync target from Mac)
├── assets-game2/     # game files (not in repo)
├── prefixes/         # Wine prefixes
├── logs/
├── tls/              # optional HTTPS certs
└── backups/
```

| Item | Value |
|------|-------|
| Mac project mirror | `synology-ra2-arch/` in this repo |
| Image | `ra2-lan-party:ultra` |
| Docker network | bridge `ra2-lan-party_ra2_lan` |
| Player 1 container IP | **172.22.20.11** |
| Player 2 container IP | **172.22.20.12** |
| Production profile | `RA2_COMPOSE_ULTRA=1` |

**Play URLs:**

| Player | LAN | Remote (DDNS) |
|--------|-----|---------------|
| 1 | `https://192.168.0.193:6081/` | `https://peterjfrancoiii2.synology.me:6081/` |
| 2 | `https://192.168.0.193:6082/` | `https://peterjfrancoiii2.synology.me:6082/` |

**Deploy from Mac:**
```bash
cd synology-ra2-arch
NAS_HOST=MediaServer2 sh scripts/sync-to-nas.sh
NAS_HOST=MediaServer2 sh scripts/redeploy-ultra.sh
```

**On NAS:**
```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
sudo sh scripts/verify-deployment.sh
```

Docs: `docs/GOLDEN_MASTER.md`, `docs/DEPLOY_SYNOLOGY.md`, `docs/ULTRA_LIGHT_ARCH_STREAMING.md`

---

## Port map (reserved / in use)

| Port | Protocol | Service |
|------|----------|---------|
| 5000/5001 | TCP | DSM HTTP/HTTPS |
| 8080 | TCP | qBittorrent Web UI (via Gluetun) |
| 6881 | TCP+UDP | BitTorrent (via Gluetun) |
| 6081 | TCP | RA2 player 1 (ultra stream) |
| 6082 | TCP | RA2 player 2 (ultra stream) |
| 23921 | TCP | SSH |
| 10443 | TCP | DSM remote HTTPS (router forward → 5001) |
| 41641 | UDP | Tailscale direct peering (optional forward) |

Router should forward **6081–6082** for remote RA2 play. Do **not** forward 8080 publicly.

---

## Installed Synology packages (selected)

| Package | Notes |
|---------|-------|
| ContainerManager 24.0.2 | Docker |
| Tailscale 1.58.2 | Remote access / Moonlight experiments |
| PlexMediaServer | `/volume2/PlexMediaServer` |
| SynologyDrive | |
| WebStation | |
| DownloadStation | Installed; **not** used for VPN downloads |
| Virtualization | |
| HyperBackup, AntiVirus, SMB | |

---

## Mac ↔ NAS workflow

| Task | Command |
|------|---------|
| SSH (remote) | `ssh MediaServer2` |
| SSH (LAN) | `ssh MediaServer2Local` |
| Sync RA2 project | `NAS_HOST=MediaServer2 sh scripts/sync-to-nas.sh` |
| Redeploy RA2 ultra | `NAS_HOST=MediaServer2 sh scripts/redeploy-ultra.sh` |
| Restart qBit stack | `ssh MediaServer2Local 'cd /volume2/Data/docker/qbit-gluetun && sudo docker compose restart'` |

---

## Design rules (do not break)

1. **Volume 2 / `Data`** for all persistent user-managed data.
2. **NAS host** does not use Surfshark as default route (DDNS stays on home WAN IP).
3. **qBittorrent only** through Gluetun (kill-switch isolation).
4. **RA2 ports 6081/6082** — never bind RA2 to 8080 (qBit conflict).
5. **RA2 project files** stay under `/volume2/Data/App_Development/ra2-lan-party/`.
6. **No secrets** in git, docs, or chat (VPN creds in `.env` on NAS only).

---

## Troubleshooting cheatsheet

| Symptom | Check |
|---------|-------|
| Gluetun won't start | `/dev/net/tun` missing → run boot script or `sudo modprobe tun && sudo mknod /dev/net/tun c 10 200` |
| qBit stuck on metadata | Settings → Proxy = **None**; use `.torrent` file not Search tab; try US VPN exit |
| RA2 unreachable remotely | Router TCP 6081–6082 → 192.168.0.193; DDNS resolves to home WAN |
| SSH timeout on LAN | Use `MediaServer2` (DDNS) instead of `MediaServer2Local` |
| Sudo prompts over SSH | Re-run `enable-passwordless-sudo.sh` after DSM update |

---

## Related files in this repo

| Doc | Purpose |
|-----|---------|
| `docs/GOLDEN_MASTER.md` | RA2 production lock / restore |
| `docs/DEPLOY_SYNOLOGY.md` | Full RA2 deploy guide |
| `Research/SYNOLOGY_DS225P_ROADMAP_UPDATED_20260608.md` | Audit + storage conventions |
| `scripts/enable-passwordless-sudo.sh` | Sudo bootstrap |
| `/volume2/Data/docker/qbit-gluetun/docker-compose.yml` | VPN download stack (on NAS) |
