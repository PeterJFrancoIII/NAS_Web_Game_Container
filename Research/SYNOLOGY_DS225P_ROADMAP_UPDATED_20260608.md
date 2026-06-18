# Synology DS225+ Roadmap

**Device:** Synology DS225+  
**Hostname:** MediaServer2  
**DSM:** 7.3.2-86009 Update 3  
**Kernel:** Linux 5.10.55+ x86_64  
**Primary data root:** `/volume2/Data`  
**Primary network/DDNS route:** LAN via `ovs_eth0` / home router `192.168.0.1`  
**Download VPN strategy:** qBittorrent routed through Gluetun container stack  
**Audit source:** `synology_audit_20260608_162415.tar.gz`  
**Roadmap purpose:** Preserve NAS naming conventions, volume layout, service placement rules, and future setup decisions.

---

## 1. Operating Principles

### 1.1 Storage placement rule

All persistent data-related objects should live on **Volume 2**, inside the shared folder named **Data**.

Canonical root:

```text
/volume2/Data
```

Avoid placing long-term application data, downloads, media libraries, Docker configs, or project data under `/volume1` unless there is a specific reason.

### 1.2 Shared-folder role convention

| Shared folder | Observed location | Role | Rule |
|---|---:|---|---|
| `Data` | `/volume2/Data` | Canonical user data root | Primary location for user-managed persistent files. |
| `docker` | `/volume2/docker` | Synology-created Docker shared folder | Keep available, but prefer `/volume2/Data/docker` for user-managed compose/config. |
| `PlexMediaServer` | `/volume2/PlexMediaServer` | Plex package share/data | Leave package-managed. |
| `web` | `/volume2/web` | Web Station share | Leave package-managed unless intentionally hosting sites. |
| `homes` | `/volume2/homes` | DSM user homes | Leave DSM-managed. |
| `Media` | `/volume1/Media` | Legacy/media share | Existing data lives here; do not expand unless intentionally retaining this split. |

### 1.3 Volume role convention

| Volume | Size | Used | Free | Role |
|---|---:|---:|---:|---|
| `/volume1` | 8.8T | 2.6T | 6.2T | Existing media/legacy volume. Avoid new data unless intentionally using `Media`. |
| `/volume2` | 8.8T | 1.7T | 7.1T | Primary data and package/app volume. |
| `/volume2/Data` | part of `/volume2` | — | — | Canonical parent for user-managed persistent objects. |

### 1.4 Naming style

Use simple, descriptive folder names. For container service directories, prefer lowercase.

Examples:

```text
/volume2/Data/docker
/volume2/Data/docker/gluetun
/volume2/Data/docker/qbittorrent
/volume2/Data/docker/vpn-downloads
/volume2/Data/downloads
/volume2/Data/downloads/incomplete
/volume2/Data/_system_audits
```

---

## 2. Current Verified System Facts

| Item | Verified value |
|---|---|
| NAS model | `DS225+` |
| Hostname | `MediaServer2` |
| Architecture | `x86_64` |
| DSM version | `7.3.2-86009 Update 3` |
| DSM build date | `2026/03/17` |
| Kernel | `Linux 5.10.55+` |
| SSH alias used from Mac | `MediaServer2` |
| SSH user observed | `Viper117` |
| Main LAN IP 1 | `192.168.0.193` on `ovs_eth0` |
| Main LAN IP 2 | `192.168.0.194` on `ovs_eth1` |
| Default gateway | `192.168.0.1` via `ovs_eth0` |
| Tailscale/tun interface | `tun1000`, `169.254.244.181/21` |
| Docker/Container package | `ContainerManager-24.0.2-1606` |
| qBittorrent image | `lscr.io/linuxserver/qbittorrent:latest` |
| Gluetun image | `qmcgaw/gluetun:latest` |
| Gluetun container status | Up 2 days, healthy at audit time |
| qBittorrent container status | Up 41 hours at audit time |

---

## 3. Storage and RAID Findings

### 3.1 Disk and volume layout

DSM system partitions are mirrored:

```text
md0: RAID1, 2/2 disks active, system root
md1: RAID1, 2/2 disks active, swap/system support
```

Data volumes are separate single-member RAID1 arrays in the audit output:

```text
md2: active raid1 sata1p5[0], 1/1 active, backs /volume1
md3: active raid1 sata2p5[0], 1/1 active, backs /volume2
```

This means `/volume1` and `/volume2` appear to be independent storage pools/volumes, each currently healthy according to `/proc/mdstat`, but each data array showed `1/1` active in the captured audit rather than a two-disk mirrored data array.

### 3.2 Current space usage

```text
/volume1: 8.8T total, 2.6T used, 6.2T free, 30% used
/volume2: 8.8T total, 1.7T used, 7.1T free, 19% used
/root:    7.7G total, 1.4G used, 6.2G free, 18% used
```

### 3.3 Important storage note

`/volume2/Data/_system_audits` was created by root during audit collection. Some folders/files were created with restrictive root permissions:

```text
d---------+ root root synology_audit_20260608_162415
----------+ root root synology_audit_20260608_162415.tar.gz
```

This is why direct `scp` failed, but `ssh MediaServer2 'cat ...'` worked. For future audits, prefer writing the final archive with readable permissions:

```bash
sudo chmod 644 /volume2/Data/_system_audits/*.tar.gz
sudo chmod 755 /volume2/Data/_system_audits/synology_audit_*
```

---

## 4. Current `/volume2/Data` Layout

Observed top-level and key subfolders:

```text
/volume2/Data
/volume2/Data/Games
/volume2/Data/Games/1 Packed - Compressed
/volume2/Data/Games/2 Unpacked - Ready to Play
/volume2/Data/Peter - Drive
/volume2/Data/Peter - Drive/chatgptprojects-claude-code
/volume2/Data/Peter Documents
/volume2/Data/Peter Documents/Business Licenses & Incorporation
/volume2/Data/Peter Documents/Ebooks
/volume2/Data/Programs
/volume2/Data/Scripts
/volume2/Data/Scripts/network
/volume2/Data/docker
/volume2/Data/docker/gluetun
/volume2/Data/docker/qbittorrent
/volume2/Data/docker/qbit-gluetun
/volume2/Data/docker/vpn-downloads
/volume2/Data/_system_audits
```

### 4.1 Canonical folder decisions

| Purpose | Canonical path |
|---|---|
| Docker project roots | `/volume2/Data/docker` |
| Gluetun config | `/volume2/Data/docker/gluetun` |
| qBittorrent config | `/volume2/Data/docker/qbittorrent` |
| qBittorrent/Gluetun compose project | `/volume2/Data/docker/vpn-downloads` or `/volume2/Data/docker/qbit-gluetun` |
| System audits | `/volume2/Data/_system_audits` |
| Network scripts | `/volume2/Data/Scripts/network` |
| Personal documents | `/volume2/Data/Peter Documents` |
| Synology Drive projects | `/volume2/Data/Peter - Drive` |

### 4.2 Item to clean up later

Both of these exist:

```text
/volume2/Data/docker/vpn-downloads
/volume2/Data/docker/qbit-gluetun
```

Pick **one** as the canonical compose project and archive/remove the other after confirming where the active container stack was launched from.

Recommended canonical choice:

```text
/volume2/Data/docker/vpn-downloads
```

---

## 5. Network and Remote Access Design

### 5.1 Desired network behavior

```text
DSM / DDNS / NAS services -> Home LAN / TP-Link router
qBittorrent downloads -> Gluetun container -> Surfshark VPN
```

The NAS itself should **not** use Surfshark as its global default gateway. This prevents Synology DDNS from publishing a Surfshark exit IP instead of the home WAN IP.

### 5.2 Verified routing state

Current system default route:

```text
default via 192.168.0.1 dev ovs_eth0 src 192.168.0.193
```

Current LAN addresses:

```text
ovs_eth0: 192.168.0.193/24
ovs_eth1: 192.168.0.194/24
```

Current additional tunnel interface:

```text
tun1000: 169.254.244.181/21
```

Installed Tailscale package:

```text
Tailscale-1.58.2-700058002
```

### 5.3 DDNS rule

Synology DDNS should resolve to the router's real home WAN IP, not the Surfshark VPN exit IP.

Known hostname used during setup:

```text
peterjfrancoiii2.synology.me
```

### 5.4 Router forwarding convention

For DSM remote access, prefer a non-default external port:

```text
External TCP 10443 -> NAS TCP 5001
```

Do not expose qBittorrent Web UI publicly.

---

## 6. Container Strategy

### 6.1 Verified container state

Current containers:

```text
gluetun      qmcgaw/gluetun:latest                    Up 2 days, healthy
qbittorrent  lscr.io/linuxserver/qbittorrent:latest   Up 41 hours
```

Current images:

```text
qmcgaw/gluetun:latest                    45MB
lscr.io/linuxserver/qbittorrent:latest   193MB
busybox:latest                           4.45MB
```

### 6.2 Published Gluetun/qBittorrent ports

The audit shows Gluetun publishing:

```text
8080/tcp -> qBittorrent Web UI via Gluetun
6881/tcp -> torrent TCP
6881/udp -> torrent UDP
```

This is consistent with the intended architecture where qBittorrent shares Gluetun's network path.

### 6.3 Preferred download stack

```text
Gluetun = VPN network container
qBittorrent = download client routed through Gluetun
```

This design provides the practical kill switch: if Gluetun/VPN is unavailable, qBittorrent should lose network connectivity instead of falling back to LAN.

### 6.4 Canonical compose template

> Do not store Surfshark secrets in notes, screenshots, or chat. Replace placeholders locally on the NAS.

```yaml
services:
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "8080:8080/tcp"
      - "6881:6881/tcp"
      - "6881:6881/udp"
    volumes:
      - /volume2/Data/docker/gluetun:/gluetun
    environment:
      - VPN_SERVICE_PROVIDER=surfshark
      - VPN_TYPE=wireguard
      - WIREGUARD_PRIVATE_KEY=PASTE_SURFSHARK_WIREGUARD_PRIVATE_KEY_HERE
      - WIREGUARD_ADDRESSES=PASTE_SURFSHARK_WIREGUARD_ADDRESS_HERE
      - SERVER_COUNTRIES=United States
      - TZ=America/New_York
      - FIREWALL=on
    restart: unless-stopped

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    network_mode: "service:gluetun"
    depends_on:
      - gluetun
    environment:
      - PUID=REPLACE_WITH_VIPER117_UID
      - PGID=REPLACE_WITH_VIPER117_GID
      - TZ=America/New_York
      - WEBUI_PORT=8080
    volumes:
      - /volume2/Data/docker/qbittorrent:/config
      - /volume2/Data/downloads:/downloads
    restart: unless-stopped
```

---

## 7. Installed Synology Packages

Key installed packages from audit:

```text
DownloadStation-4.1.2-5012
MediaServer-2.2.1-3406
SynologyDrive-4.0.3-27892
WebStation-4.3.0-0528
Virtualization-2.7.0-12229
ContainerManager-24.0.2-1606
Tailscale-1.58.2-700058002
PlexMediaServer-1.43.2.10687-720010687
HyperBackup-4.2.1-4228
AntiVirus-1.6.0-4005
SMBService-4.15.13-3047
```

### 7.1 Download Station policy

Download Station is installed under `/volume2/@appstore/DownloadStation`, but the preferred VPN-isolated download design is qBittorrent + Gluetun.

Rule:

```text
Use qBittorrent + Gluetun for VPN-isolated downloads.
Do not rely on Download Station for VPN isolation.
```

---

## 8. Verification Commands

### 8.1 Confirm NAS routing stays on LAN

```bash
ip route
wget -qO- https://ipinfo.io/ip
```

Expected:

```text
Default route remains via 192.168.0.1 on ovs_eth0.
Public IP equals home WAN IP, not Surfshark.
```

### 8.2 Confirm Gluetun/qBittorrent routing

```bash
docker ps -a
docker logs --tail=100 gluetun
docker exec gluetun wget -qO- https://ipinfo.io/ip
```

Expected:

```text
Gluetun public IP = Surfshark VPN IP
NAS public IP = home WAN IP
```

### 8.3 Confirm qBittorrent uses Gluetun namespace

```bash
docker inspect qbittorrent | grep -i networkmode
```

Expected:

```text
"NetworkMode": "container:<gluetun-container-id>"
```

or equivalent `service:gluetun` when viewed from compose config.

### 8.4 Confirm active compose project path

Run both checks:

```bash
find /volume2/Data/docker -maxdepth 3 \( -iname 'docker-compose.yml' -o -iname 'compose.yml' -o -iname '*.yaml' -o -iname '*.yml' \) -print

docker inspect gluetun | grep -i com.docker.compose.project.working_dir -A 1
```

Use the reported working directory as the actual source of truth.

---

## 9. Security Rules

### 9.1 Do not expose qBittorrent publicly

Do not create router port forwards for:

```text
8080
6881
```

qBittorrent Web UI should be reachable only from LAN or trusted private VPN access.

### 9.2 DSM exposure preference

If DSM must be accessible from the internet, prefer:

```text
External TCP 10443 -> NAS TCP 5001
```

Avoid exposing DSM HTTP port `5000`.

### 9.3 Account protection

Keep enabled:

```text
HTTPS only
Auto Block
Account Protection
2FA where practical
Disable default admin account
DSM updates
Package updates
```

---

## 10. Maintenance Notes

### 10.1 After DSM/package updates

Check:

```bash
docker ps
docker logs gluetun --tail=100
docker logs qbittorrent --tail=100
ls -l /dev/net/tun
ip route
```

### 10.2 If VPN stops working

```bash
docker restart gluetun
docker logs -f gluetun
```

If `/dev/net/tun` is missing:

```bash
sudo mkdir -p /dev/net
sudo mknod /dev/net/tun c 10 200
sudo chmod 600 /dev/net/tun
```

### 10.3 If downloads have permission errors

```bash
id Viper117
ls -lah /volume2/Data/downloads
ls -lah /volume2/Data/docker/qbittorrent
```

Then correct ownership using the chosen UID/GID policy.

### 10.4 If future audits need to be collected

Use the key alias from the Mac:

```bash
ssh MediaServer2
```

To pull an audit archive from the NAS without scp/SFTP:

```bash
ssh MediaServer2 'cat /volume2/Data/_system_audits/synology_audit_YYYYMMDD_HHMMSS.tar.gz' > ~/Desktop/synology_audit_YYYYMMDD_HHMMSS.tar.gz
```

---

## 11. Open Items To Confirm

| Item | Status |
|---|---|
| `/volume2/Data` shared folder exists | Confirmed |
| DS model | Confirmed `DS225+` |
| DSM version | Confirmed `7.3.2-86009 Update 3` |
| LAN default route | Confirmed via `192.168.0.1` on `ovs_eth0` |
| qBittorrent container exists | Confirmed |
| Gluetun container exists | Confirmed healthy |
| Container ports | Confirmed `8080`, `6881/tcp`, `6881/udp` published on Gluetun |
| Confirm qBittorrent network mode is Gluetun | Needs `docker inspect qbittorrent` |
| Confirm active compose project path | Needs `docker inspect gluetun` or compose file scan output |
| Confirm `Viper117` UID/GID | Needs `id Viper117` |
| Confirm qBittorrent Web UI first-login password | Needs `docker logs qbittorrent` if not already changed |
| Confirm Gluetun public IP is Surfshark | Needs `docker exec gluetun wget -qO- https://ipinfo.io/ip` |
| Confirm NAS system public IP remains home WAN | Needs `wget -qO- https://ipinfo.io/ip` from NAS shell |
| Confirm DDNS resolves to home WAN IP | Needs DNS check from outside LAN |
| Confirm whether `/volume1/Media` remains intentional | Needs user decision |
| Confirm whether `vpn-downloads` or `qbit-gluetun` is canonical | Needs compose working dir check |

---

## 12. Change Log

### 2026-06-08

- Imported audit archive `synology_audit_20260608_162415.tar.gz`.
- Confirmed DS225+, DSM 7.3.2-86009 Update 3, hostname `MediaServer2`, x86_64 kernel.
- Confirmed `/volume2/Data` exists and contains Docker, Scripts, system audits, documents, games, programs, and project folders.
- Confirmed `/volume1` and `/volume2` are both 8.8T Btrfs volumes with substantial free space.
- Confirmed default NAS route uses LAN gateway `192.168.0.1` via `ovs_eth0`, preserving DDNS/LAN design.
- Confirmed qBittorrent and Gluetun containers are present and running; Gluetun was healthy at audit time.
- Confirmed installed packages include Container Manager, Tailscale, Plex, Download Station, Synology Drive, Web Station, Virtualization, Hyper Backup, and AntiVirus.
- Added permission note for root-created audit files under `/volume2/Data/_system_audits`.
- Added open items for compose path, UID/GID, public IP checks, and qBittorrent network-mode verification.

### 2026-06-05

- Created initial Synology DS225+ roadmap.
- Captured known system facts from SSH session.
- Defined Volume 2 / Data as canonical location for persistent data-related objects.
- Defined qBittorrent + Gluetun as preferred VPN-isolated download architecture.
- Preserved DDNS/LAN as the normal route for DSM and NAS services.
