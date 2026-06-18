# MediaServer2 (DS225+) — Quick Reference

Last verified: **2026-06-15** via SSH (`MediaServer2` over DDNS while VPN'd) **and browser end-to-end over VPN**. RA2 **remote WebRTC**: diagnosed the WSS-fallback as a **NAT-hairpin trap** (NAS can't reach its own public IP) and fixed it with **server-side TURN via LAN coturn** in `webrtc-media-helper.c`. Confirmed working: RA2 video streams remotely over **UDP relay** (`selected pair … localRelayProtocol:"udp"`, framesDecoded rising), coturn shows the server's own relay from `192.168.0.193` carrying bidirectional media (`peer usage rp≈2000/interval`).

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

**Remote WebRTC (DDNS / VPN):** On remote pages (`*.synology.me`) the client uses **relay-first** ICE (`iceTransportPolicy: "relay"`) and does one relay-only reconnect before WSS fallback. Verify the relay path from a VPN'd Mac **before** debugging the browser:

```bash
sh scripts/probe-webrtc-turn-remote.sh        # expect: relay allocated on 2/2 transport(s)
```

Then open `https://peterjfrancoiii2.synology.me:6081/` (hard refresh) — transport panel should show `udp video: WebRTC verified` with rising `webrtc rtp:`. Use `?relayOnly=1` to force relay-only for isolation. `coturn/update_coturn_ip.sh` runs during `redeploy-ultra.sh` to keep `external-ip` in sync with the WAN IP (stale WAN IP breaks remote relay candidates).

> **NAT hairpin trap + server-side TURN (fixed 2026-06-15).** This router does **not** hairpin (the NAS can't reach its own public IP: `curl https://108.2.161.76:6081` from the NAS times out; the LAN IP returns 200). Because the media server is **on the same NAS** as coturn, it could never send video back to the browser's relay candidate (advertised on the public IP) → remote always fell back to WSS even though the relay allocated. Fix: `webrtc-media-helper.c` now adds the **LAN** coturn as a server-side TURN server (`turn://…@192.168.0.193:62011`) so the server relays outbound over the LAN and coturn bridges the two allocations internally. Confirm server-side:
> ```bash
> ssh MediaServer2 'sudo /usr/local/bin/docker logs --tail 200 RA2_Coturn | grep -aE "192\.168\.0\.193.*ALLOCATE processed, success"'   # server's own relay
> ```
> **Deploy note:** the helper `.c` files are bind-mounted `:ro` and recompiled at container start (`WEBRTC_RECOMPILE_HELPER=1`). To ship a `.c` change: `NAS_HOST=MediaServer2 RA2_ULTRA_BUILD=0 sh scripts/redeploy-ultra.sh` (sync + **recreate without image rebuild** re-resolves the bind mount and recompiles). A full image rebuild (`RA2_ULTRA_BUILD=1`) is only needed for new system packages.
>
> **Red herring — empty-user `401 Unauthorized` in coturn is NOT a failure.** A VPN'd browser gathers TURN candidates from **every** local interface (IPv6, the VPN tunnel `10.14.0.x`, the LAN `192.168.0.x`). All the non-working interfaces emit `icecandidateerror 701` and credential-less `user <> … 401` TCP attempts that coturn logs then closes. Only the one working interface (the VPN exit) actually allocates — look for the browser's **successful UDP** allocation and the server's `192.168.0.193` relay with non-zero **`peer usage`**. Don't chase the `401`s; chase whether `peer usage rp/rb` is climbing.

Docs: `docs/GOLDEN_MASTER.md`, `docs/GOLDEN_MASTER_UDP_LAN.md`, `docs/DEPLOY_SYNOLOGY.md`, `docs/ULTRA_LIGHT_ARCH_STREAMING.md`

---

## Port map (reserved / in use)

| Port | Protocol | Service |
|------|----------|---------|
| 5000/5001 | TCP | DSM HTTP/HTTPS |
| 8080 | TCP | qBittorrent Web UI (via Gluetun) |
| 6881 | TCP+UDP | BitTorrent (via Gluetun) |
| 6081 | TCP | RA2 player 1 (ultra stream) |
| 6082 | TCP | RA2 player 2 (ultra stream) |
| 62001–62040 | UDP + TCP | WebRTC media + TURN (62011) + coturn relay (62012–62020) |
| 5349 | TCP | TURNS — **gated off** (`WEBRTC_TURNS_ENABLED=0`); self-signed cert, browsers reject `turns:` |
| 23921 | TCP | SSH |
| 10443 | TCP | DSM remote HTTPS (router forward → 5001) |
| 41641 | UDP | Tailscale direct peering (optional forward) |

Router should forward **6081–6082** (TCP) and **62001–62040** (UDP+TCP) for remote RA2 UDP play — plain TURN on **62011 (UDP+TCP)** is the confirmed VPN-friendly relay path. **5349 (TCP)** is only useful once coturn has a cert valid for `peterjfrancoiii2.synology.me`; until then leave TURNS gated off. Do **not** forward 8080 publicly.

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
| RA2 remote falls back to WSS video | `sh scripts/probe-webrtc-turn-remote.sh` (expect 2/2 relay); confirm router UDP+TCP 62001–62040; check `update_coturn_ip.sh` ran (fresh `external-ip`); hard-refresh browser for latest `?v=`. **If the relay allocates but media never flows → NAT-hairpin trap:** confirm the helper added server-side TURN (`docker logs Cloud_Gaming_Player1 \| grep "server-side TURN relay added"`) and coturn shows a `192.168.0.193 … ALLOCATE … success` (server's own relay). |
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
