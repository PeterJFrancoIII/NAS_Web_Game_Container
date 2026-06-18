# NAS Deploy Status

**Golden master tag:** `golden-master-2026-06-udp-lan` (locked **15 June 2026**)  
**UDP LAN + remote:** verified — see [`GOLDEN_MASTER_UDP_LAN.md`](GOLDEN_MASTER_UDP_LAN.md)  
**Host:** MediaServer2 / `192.168.0.193` / `peterjfrancoiii2.synology.me`

## Production (verified)

| Item | Status |
|------|--------|
| Image | `ra2-lan-party:ultra` |
| `Cloud_Gaming_Player1` | Port 6081 · host network (UDP) |
| `Cloud_Gaming_Player2` | Port 6082 |
| `RA2_Coturn` | TURN 62011 · relay 62012–62020 |
| Client | `webrtc-ice-utils.js?v=102`, `ultra-play.js?v=102` (`SETTINGS_VERSION=66`) |
| Transport | WebRTC H.264 UDP (LAN direct or remote relay) + WSS audio/input |
| Remote UDP | Server-side TURN via LAN coturn (NAT hairpin bypass) |

## URLs

```text
Player 1: https://peterjfrancoiii2.synology.me:6081/
Player 2: https://peterjfrancoiii2.synology.me:6082/
LAN P1:   https://192.168.0.193:6081/
```

## Operator commands

```bash
cd /volume2/Data/App_Development/ra2-lan-party/project
RA2_COMPOSE_ULTRA=1 RA2_COMPOSE_ULTRA_UDP=1 RA2_COMPOSE_ULTRA_UDP_HOST=1 sh scripts/redeploy-ultra.sh
sudo sh scripts/restart-audio-ultra.sh ra2-player-1
sh scripts/backup-golden-master.sh
sh scripts/run-webrtc-tests.sh
```

From Mac:

```bash
NAS_HOST=MediaServer2 RA2_ULTRA_BUILD=0 sh scripts/redeploy-ultra.sh
NAS_HOST=MediaServer2 sh scripts/backup-golden-master.sh
sh scripts/probe-webrtc-turn-remote.sh   # VPN on — expect 2/2 relay
```
