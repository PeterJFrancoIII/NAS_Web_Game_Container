# Golden Master — LAN UDP WebRTC Video (June 2026)

**Tag:** `golden-master-2026-06-udp-lan`  
**Parent:** [`GOLDEN_MASTER.md`](GOLDEN_MASTER.md)  
**Verified:** Local LAN play on DS225+ — transport shows **`udp video: WebRTC verified/`** with rising **`webrtc rtp:`** counters.

Split-protocol ultra streaming: **UDP/WebRTC video** + **WSS** for audio, input, and game selection.

---

## 1. Compose stack (locked)

```bash
compose.yaml
  + compose.https.yaml
  + compose.ultra.yaml
  + compose.ultra-udp.yaml
  + compose.ultra-udp-host.yaml   # player 1 only — host network for WebRTC
  + compose.player1-network.yaml   # player 2 bridge IP (when host overlay off for P2)
```

**Environment flags (`.env`):**

| Flag | Value | Purpose |
|------|-------|---------|
| `RA2_COMPOSE_ULTRA` | `1` | Ultra browser profile |
| `RA2_COMPOSE_ULTRA_UDP` | `1` | WebRTC video + coturn |
| `RA2_COMPOSE_ULTRA_UDP_HOST` | `1` | Player 1 host network (fixes Synology Docker UDP masquerade) |

**Deploy (runs WebRTC unit tests first):**

```bash
RA2_COMPOSE_ULTRA=1 RA2_COMPOSE_ULTRA_UDP=1 RA2_COMPOSE_ULTRA_UDP_HOST=1 \
  sh scripts/redeploy-ultra.sh
```

---

## 2. Port map

| Port(s) | Protocol | Scope | Purpose |
|---------|----------|-------|---------|
| **6081** | TCP HTTPS/WSS | Internet + LAN | Player 1 play page, `/stream`, `/webrtc-signal` |
| **6082** | TCP HTTPS/WSS | Internet + LAN | Player 2 |
| **62001–62010** | UDP + TCP | LAN + router forward | Player 1 WebRTC RTP/ICE |
| **62011** | UDP + TCP | LAN + router forward | Coturn (TURN) |
| **62015–62020** | UDP | LAN + router forward | Coturn relay ports |
| **5349** | TCP TLS | Remote (optional) | TURNS fallback |

WSS remains on **6081** only for remote play — no extra signaling ports forwarded.

---

## 3. Key files (UDP path)

| Path | Role |
|------|------|
| `container/webrtc-media.py` | WebRTC signaling bridge; LAN+public ICE expansion |
| `container/webrtc-media-helper.c` | GStreamer webrtcbin H.264 encode |
| `container/remote-ultra/webrtc-ice-utils.js` | Testable ICE helpers (mDNS rewrite, LAN TURN URLs) |
| `container/remote-ultra/ultra-play.js` | Browser client — **`SETTINGS_VERSION=49`**, `?v=81` |
| `coturn/turnserver.conf` | Static TURN creds, TLS on 5349 |
| `compose.ultra-udp.yaml` | UDP overlay + `RA2_Coturn` |
| `compose.ultra-udp-host.yaml` | Player 1 `network_mode: host` |
| `scripts/run-webrtc-tests.sh` | Pre-deploy ICE unit tests |
| `scripts/probe-webrtc-turn.sh` | NAS TURN health probe |

---

## 4. Browser verification (LAN)

1. Open **`https://192.168.0.193:6081/`** (prefer LAN IP over DDNS on same subnet).
2. Hard refresh: **Cmd+Shift+R**.
3. Start a game session.
4. Transport panel must show:
   - `udp video: WebRTC verified/low` (or your latency preset)
   - `webrtc path: …` (often `relay/udp → host` on LAN via TURN)
   - `webrtc rtp: N pkts · X KB` — **N increases** every few seconds
   - `wss video rx: M (should stop increasing)` — **M freezes** after verification

Console: `[ultra-play] selected pair` with `packetsReceived > 0`.

**Not verified yet:** remote DDNS UDP (requires router UDP forwards + hairpin/NAT testing).

---

## 5. NAS verification

```bash
# Unit tests (local or NAS checkout)
sh scripts/run-webrtc-tests.sh

# TURN + hello ICE creds
ssh MediaServer2Local 'cd /volume2/Data/App_Development/ra2-lan-party/project && sh scripts/probe-webrtc-turn.sh'

# Recent session — expect client ICE srflx/relay, useful>0, no "candidates: 0"
ssh MediaServer2Local 'sudo docker logs Cloud_Gaming_Player1 2>&1 | grep -E "client ICE|remote answer|useful|verified" | tail -20'
```

Good session log markers:

- `client ICE … typ=srflx` or `typ=relay`
- `remote answer applied … "types": {"relay": N, "srflx": M}` with N+M > 0
- `end-of-candidates from client … (useful=N)` with N > 0
- `ice-connection-state=3` on helper

---

## 6. Locked invariants (UDP)

1. **Never ship answer SDP with zero ICE candidates** — mDNS must be rewritten to LAN IP before strip.
2. **Server ICE advertises both** `NAS_LAN_IP` and public DDNS IP (dual candidates).
3. **Replay cached server ICE** to browser after offer (trickle race fix).
4. **Confirm UDP only after RTP** — `webrtcMediaVerified` + inbound-rtp `packetsReceived > 0`.
5. **Coturn runs as uid 1000** — reads TLS key at `/opt/ra2/tls/key.pem`.
6. **Player 1 host network** when `RA2_COMPOSE_ULTRA_UDP_HOST=1`.
7. **`sh scripts/run-webrtc-tests.sh`** passes before `redeploy-ultra.sh` sync.

---

## 7. Backup this golden master

```bash
# On NAS (or from Mac)
cd /volume2/Data/App_Development/ra2-lan-party/project
NAS_HOST=MediaServer2Local sh scripts/backup-golden-master.sh
```

Archive label: **`golden-master-2026-06-udp-lan`**

---

**Lock date:** 14 June 2026
