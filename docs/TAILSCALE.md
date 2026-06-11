# Tailscale Remote Access for Moonlight

Do **not** expose GameStream ports (`47984-48010` TCP, `47998-48000` UDP) directly to the internet. Use Tailscale for remote Moonlight access instead.

WebRTC fallback (`6081-6086` TCP, `62001-62040` UDP/TCP) may still need router forwards if you rely on browser remote play — but production play should use Moonlight over Tailscale.

## Deploy Tailscale sidecar

1. Create a reusable auth key in the [Tailscale admin console](https://login.tailscale.com/admin/settings/keys).
2. Add to `.env`:

```bash
TAILSCALE_AUTHKEY=tskey-auth-...
TAILSCALE_HOSTNAME=ra2-nas
```

3. Start:

```bash
mkdir -p data/tailscale/state
docker compose --env-file .env -f compose.tailscale.yaml up -d
```

Or via overlay flag:

```bash
RA2_COMPOSE_TAILSCALE=1 sh -c '. ./scripts/lib.sh; run_compose .env up -d'
```

## Encourage direct peer connections (avoid DERP)

Tailscale falls back to DERP relay servers when NAT traversal fails. DERP adds latency unsuitable for game streaming.

Forward **only** this port on your edge router:

```text
External UDP 41641 → NAS LAN IP (192.168.0.193) UDP 41641
```

Verify before latency testing:

```bash
sh scripts/check-tailscale-direct.sh ra2-nas
```

Healthy output shows `tailscale ping` succeeding **without** `via DERP`.

## Connect Moonlight remotely

1. Install Tailscale on the client device (Mac, iPad, etc.).
2. Note the NAS Tailscale IP (`100.x.y.z`) from `tailscale status`.
3. In Moonlight, add host using the **Tailscale IP**, not the public DDNS hostname.
4. Keep Sunshine/Wolf bound to host networking on the NAS.

## LAN vs remote testing

- **LAN tests first:** Moonlight → NAS LAN IP (`192.168.0.193`).
- **Remote tests second:** Moonlight → NAS Tailscale IP after direct-path verification.
- Do not compare LAN and remote latency in the same session.

## WebRTC fallback over Tailscale (optional)

If you must use browser WebRTC remotely, Tailscale can replace DDNS port forwarding for control channels (`6083-6086`). Media ports still require ICE reachability — run:

```bash
sh scripts/check-webrtc-ice-reachability.sh
```

Prefer Moonlight for production; WebRTC is legacy fallback only.

## Security notes

- GameStream ports stay closed on the public internet.
- Tailscale auth keys are secrets — do not commit `.env`.
- Revoke compromised keys in the Tailscale admin console.
