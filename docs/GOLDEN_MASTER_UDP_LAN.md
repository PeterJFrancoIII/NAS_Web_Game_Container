# Golden Master — LAN + Remote UDP WebRTC Video (June 2026)

**Tag:** `golden-master-2026-06-udp-lan`  
**Parent:** [`GOLDEN_MASTER.md`](GOLDEN_MASTER.md)  
**Verified:** **LAN** — transport shows **`udp video: WebRTC verified/`** with rising **`webrtc rtp:`** at `https://192.168.0.193:6081/`. **Remote (DDNS + VPN)** — same verification at `https://peterjfrancoiii2.synology.me:6081/` with **`relay/udp`** selected pair, server-side TURN bridging via coturn (`peer usage` climbing), RA2 video decoding remotely (**2026-06-15**).

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
| **62011** | UDP + TCP | LAN + router forward | Coturn TURN listener (`turn:…:62011?transport=udp\|tcp`) |
| **62012–62020** | UDP | LAN + router forward | Coturn relay range (`min-port`/`max-port` in `turnserver.conf`) |
| **5349** | TCP TLS | Remote (optional) | TURNS — **gated off** (`WEBRTC_TURNS_ENABLED=0`) until a non-self-signed cert is installed |

WSS remains on **6081** only for remote play — no extra signaling ports forwarded.

> **TURNS / 5349 status (2026-06-15):** Coturn's TLS cert is self-signed (`CN=MediaServer2.local`), so browsers silently reject `turns:` even though the port is open. Plain TURN on **62011 (UDP *and* TCP)** is confirmed working over a client VPN (Surfshark) — see remote verification below — so TURNS is not required for the current setup. Re-enable it only after installing a cert valid for `peterjfrancoiii2.synology.me`.

---

## 3. Key files (UDP path)

| Path | Role |
|------|------|
| `container/webrtc-media.py` | WebRTC signaling bridge; LAN+public ICE expansion |
| `container/webrtc-media-helper.c` | GStreamer webrtcbin H.264 encode; **server-side TURN via LAN coturn** (`add-turn-server`, bypasses NAT hairpin for remote) |
| `container/start-webrtc.sh` | Launches bridge; **recompiles helper at start** when `WEBRTC_RECOMPILE_HELPER=1` (helper `.c` is bind-mounted `:ro`, so `.c` edits + container recreate redeploy without an image rebuild) |
| `container/remote-ultra/webrtc-ice-utils.js` | Testable ICE helpers (mDNS rewrite, LAN TURN URLs, **remote relay-first ordering**); `?v=102` |
| `container/remote-ultra/ultra-play.js` | Browser client — **relay-first on remote + ICE-failure relay reconnect**, `?v=102` |
| `coturn/turnserver.conf` | Static TURN creds, relay `62012–62020`, TLS on 5349 |
| `compose.ultra-udp.yaml` | UDP overlay + `RA2_Coturn` |
| `compose.ultra-udp-host.yaml` | Player 1 `network_mode: host` |
| `scripts/run-webrtc-tests.sh` | Pre-deploy ICE unit tests |
| `scripts/probe-webrtc-turn.sh` | NAS TURN health probe |
| `scripts/probe-webrtc-turn-remote.sh` | Remote probe from Mac (VPN on) — ports + **real TURN Allocate** |
| `scripts/turn_allocate_probe.py` | Dependency-free STUN/TURN Allocate handshake (UDP/TCP) |

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

---

## 4b. Remote verification (DDNS / VPN)

Simulate remote play with **Surfshark VPN on the Mac only** (NAS stays on home WAN — design rule). On remote pages (`*.synology.me`), the client forces **`iceTransportPolicy: "relay"`** and waits for a TURN relay candidate before answering; on ICE failure it does **one** relay-only reconnect before falling back to WSS.

> **Root cause of the remote-UDP failure (2026-06-15) — NAT hairpin + co-located media server.**
> The browser's relay candidate is advertised on the NAS **public** IP (`108.2.161.76:620xx`). The media server runs **on that same NAS**, and this router does **not** hairpin (`curl https://108.2.161.76:6081` from the NAS times out while the LAN IP returns 200). So browser→server worked (browser relay → coturn → LAN), but **server→browser-relay** could never loop back through the WAN IP → ICE never completed both ways → WSS fallback. This is exactly why LAN (direct, no relay) worked but remote did not.
>
> **Fix:** `webrtc-media-helper.c` now calls `add-turn-server` with the **LAN** coturn URI (`turn://ra2turn:…@192.168.0.193:62011`, built from `WEBRTC_TURN_USERNAME/PASSWORD` + `NAS_LAN_IP`). The server allocates its **own** relay over the LAN (no hairpin) and ICE selects the **server-relay ↔ browser-relay** pair, which coturn bridges internally. Verify server-side in coturn logs:
>
> ```bash
> ssh MediaServer2 'sudo /usr/local/bin/docker logs --tail 200 RA2_Coturn | grep -aE "192\.168\.0\.193.*ALLOCATE processed, success"'
> # expect: user <ra2turn> ALLOCATE success with remote 192.168.0.193:<port>  (the server's own relay)
> ```
>
> Helper startup log should show: `[webrtc-helper] server-side TURN relay added via 192.168.0.193:62011 (LAN egress, bypasses NAT hairpin)`.

**Step 1 — probe the relay path (proves coturn + router + creds, before opening a browser):**

```bash
sh scripts/probe-webrtc-turn-remote.sh
```

Expect `relay allocated on 2/2 transport(s)` — this runs the real STUN/TURN Allocate handshake (UDP + TCP) the browser would. A single transport passing is enough to play.

**Step 2 — browser (hard refresh `Cmd+Shift+R`):**

1. Open **`https://peterjfrancoiii2.synology.me:6081/`** and start a game.
2. Transport panel must show:
   - `udp video: WebRTC verified/…`
   - `webrtc rtp: N pkts` — **N increases**
   - `wss video rx: M` — **M freezes** after verification
   - `webrtc path:` typically `relay/udp → host` or `relay/udp → relay`
3. Console: `[ultra-play] RTCPeerConnection remote TURN relay` then `[ultra-play] selected pair`.

**Diagnostic:** `https://peterjfrancoiii2.synology.me:6081/?relayOnly=1` forces relay-only ICE — if UDP verifies here, any failure on the normal page is host/srflx pairing, not the relay path.

**Confirmed 2026-06-15 (Surfshark VPN on Mac, Chromium):** DDNS → `108.2.161.76`; TURN Allocate succeeds on UDP **and** TCP (`realm=ra2.lan.party`); `turn-ice.json` serves credentialed TURN UDP+TCP (no TURNS — gated off). **End-to-end browser play:** RA2 intro cinematic streaming at 1024×768; console `answer ICE (remote) { relay: 2 }` → `selected pair { state: "succeeded", localRelayProtocol: "udp", framesDecoded rising }`; helper `ice-connection-state=completed`; coturn server relay `192.168.0.193` shows bidirectional `peer usage` (`rp≈2000/interval`). Empty-user `401` lines from dead VPN/LAN interfaces are **noise** — only the working VPN-exit allocation matters.

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
7. **`sh scripts/run-webrtc-tests.sh`** passes before `redeploy-ultra.sh` sync (includes remote Player 1 coturn port + ICE policy contracts).
8. **Server-side TURN via LAN coturn** — `webrtc-media-helper.c` must add `turn://…@NAS_LAN_IP:62011` so the co-located media server relays outbound without NAT hairpin (required for remote UDP on this router).

---

## 7. Backup this golden master

```bash
# On NAS (or from Mac)
cd /volume2/Data/App_Development/ra2-lan-party/project
NAS_HOST=MediaServer2Local sh scripts/backup-golden-master.sh
```

Archive label: **`golden-master-2026-06-udp-lan`**

---

**Lock date:** 15 June 2026 (remote UDP verified; supersedes LAN-only lock of 14 June)
