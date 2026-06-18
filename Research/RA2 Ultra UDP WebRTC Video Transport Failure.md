# RA2 Ultra UDP WebRTC Video Transport Failure

## Bottom line

The evidence you provided makes this look much more like a **client-side ICE and media-path problem** than a signaling problem or a server-offer problem. In particular, your server reaching `ice-connection-state=completed` means ICE found and nominated at least one valid candidate pair, but that does **not** prove the browser actually received a video track or decoded frames. In WebRTC, the right proof of success on the browser side is a combination of `ontrack`, the selected candidate pair, and inbound RTP stats such as `packetsReceived`, `bytesReceived`, and `framesDecoded`. Also, a lack of *useful trickled* client ICE is **not** fatal if the answer SDP already contained the usable candidates, because “half-trickle” and full candidate sets in the initial SDP are valid ICE behavior, and GStreamer `webrtcbin` accepts candidates in the remote description. citeturn16view2turn7view5turn7view4turn4view5turn12view2

So the most likely root cause is now one of these two: **either the browser is still not gathering or advertising a usable `relay` candidate from your coturn on the failing remote networks, or it is gathering one and the browser-side code is falling back to WSS before WebRTC video is actually promoted to active playback**. The fastest way to separate those is a single **relay-only** test run with better SDP and `getStats()` logging. citeturn18view0turn7view0turn7view2turn7view3turn7view4

For a fix that is likely to work for **real remote browsers without Tailscale**, the configuration gap I would prioritize is: **prove relay candidates are present, make coturn explicitly NAT-aware with `external-ip`, and add `turns:` on TCP 443 if you want this to survive restrictive client networks**. Browsers accept TURN through `RTCConfiguration` using `urls`, `username`, and `credential`; coturn supports NAT mapping and TLS listeners; and the WebRTC transport spec explicitly requires support for TURN over TCP and TLS-over-TCP to cope with UDP-blocking firewalls. citeturn7view2turn4view2turn19view4turn24view2turn24view3turn7view1

## Why the current evidence points there

The `.local` candidates you are seeing from the browser are not unusual. Modern browsers commonly hide local IP addresses behind mDNS hostnames for privacy, and mDNS resolution has limited scope. The IETF mDNS-for-ICE draft notes that when mDNS cannot be resolved, ICE falls back to NAT hairpinning if available, or to TURN if not. In other words, **remote** WebRTC cannot rely on `.local` host candidates as the primary path. That makes your server warning about “no usable ICE” from trickle entirely plausible without meaning the whole session is doomed. citeturn4view3turn13view1turn2search7

At the same time, the server warning is only about the **trickled** candidates. GStreamer’s `webrtcbin` treats the remote description as the authoritative SDP context, and its `current-remote-description` includes the negotiated remote description plus any later trickled candidates. RFC 8838 explicitly allows a full set of candidates to be carried in the initial offer or answer, so if your browser waited for ICE gathering before emitting the answer, the usable client candidates may already be embedded there. That means **answer-SDP relay or srflx candidates can be sufficient even when all later trickle entries are useless mDNS hostnames**. citeturn12view2turn4view5turn4view6

This also explains the apparently contradictory situation where the NAS logs say ICE is completed but the page still shows WSS video. ICE completion means a valid nominated path exists for sending and receiving data on that component; it does **not** prove that the browser application has attached a remote track, that RTP packets are arriving, or that frames are being decoded and painted. The `track` event indicates that an inbound remote track has been added, and `RTCPeerConnection.getStats()` is the standard way to inspect the selected ICE pair plus inbound RTP counters. If those counters stay at zero, the transport is not actually delivering media. If they rise while the page still says WSS, the client promotion logic is wrong. citeturn16view1turn16view2turn7view5turn7view3turn23view0turn7view4turn6search5

A final interpretive point: if any of your “remote” tests were actually done from the same LAN via the public DDNS name, they are not trustworthy for this diagnosis. The mDNS draft specifically calls out NAT hairpin fallback behavior when mDNS fails, and hairpin support varies by router. So same-LAN-via-public-hostname tests can either fail for reasons that do not affect true remote users, or succeed for reasons that true remote users will never get. citeturn13view1turn13view2

## Root causes ranked by likelihood

**Most likely: the failing browser sessions still do not contain a usable `relay` candidate in the answer SDP.** Your own evidence already says client trickle is only mDNS, and STUN/srflx is often blocked on the client network. In that situation, remote media works only if TURN produces a usable `relay` candidate, because `host` candidates are private/local and `srflx` depends on STUN reachability. TURN exists precisely for the case where a direct socket path cannot be established, including symmetric-NAT-style scenarios. If your answer SDP summary shows `relay=0` on failing networks, this is the root cause. citeturn18view0turn20search2turn7view0turn13view1

**Very likely: coturn is reachable, but not fully correct for a TURN server behind home NAT.** Coturn’s own documentation is very explicit that if the TURN server is behind NAT, `external-ip` must be configured so the relayed address returned to clients is the public address, and the NAT must forward the relay ports directly. The Synapse TURN deployment guide makes the same point in practical terms: TURN behind NAT needs a public IP, port forwarding, and careful NAT handling. The fact that your coturn shares the player network namespace does **not** remove the router NAT in front of the NAS. If `external-ip` is missing or mapped to the wrong private address, the browser may fail to gather a usable relay candidate or gather one that cannot actually pass media. citeturn4view2turn19view4turn17view0

**Plausible: the browser actually establishes a relay-backed transport, but `ultra-play.js` commits to WSS fallback before first frame and never promotes WebRTC afterward.** This would fit the “server says connected, browser never switches” symptom. The browser-side discriminator is simple: if the selected candidate pair exists, the remote track fires, and `packetsReceived` or `framesDecoded` increase, then transport is working and the problem is in client state management or promotion logic, not NAT traversal. Because `track` and `getStats()` are the standard browser-side truth sources here, they should outrank your current UI status string. citeturn7view5turn7view3turn23view0turn7view4turn6search5

**Likely for some remote networks even after the above: your TURN transport matrix is not universal enough because it stops at `turn:` on port 62011.** An arbitrary port is valid, and browsers can use TURN on non-default ports, but WebRTC’s transport spec also says endpoints must support TURN over TCP and TURN over TLS-over-TCP to handle firewalls that block UDP. Coturn explicitly supports choosing alternative listener ports, including 443, specifically to get around strict NATs and firewalls. So even if `turn:peterjfrancoiii2.synology.me:62011?transport=tcp` works from many networks, it will never be as universal as `turns:...:443?transport=tcp`. citeturn7view2turn7view1turn19view4

I do **not** rank “Synology Docker quirk” or “libnice quirk” as the lead explanation. The symptom pattern maps much more cleanly to standard TURN-behind-NAT and browser candidate-gathering behavior than to a platform-specific bug. In other words, this looks like generic WebRTC/TURN plumbing that still needs one more step to become remote-safe. citeturn4view2turn17view0turn13view1turn7view1

## One decisive next experiment

Make **one** connection attempt from a genuinely remote network, but force the browser into **relay-only** mode for that attempt. The reason this is the best next experiment is that `iceTransportPolicy: "relay"` tells the browser to consider only relayed candidates, which turns your question from “is it ICE, TURN, or UI?” into a clean binary test of whether TURN is actually usable. While doing that, capture the selected candidate pair and inbound RTP stats, because those are the browser’s authoritative indicators of path choice and actual media receipt. Also log `icecandidateerror`, because a 701 there means the browser could not even reach the STUN or TURN server URL during gathering. citeturn7view2turn22view0turn7view3turn23view0turn7view4

Use this sequence for the single attempt:

1. Add a temporary query-flag path in `ultra-play.js` so `?relayOnly=1` sets `iceTransportPolicy: "relay"` on the `RTCPeerConnection`. Keep production behavior as `"all"` when the flag is absent. A relay-only attempt is purely diagnostic. citeturn7view2

2. In the same client build, log four things to the browser console:
   - an **answer SDP ICE summary** with counts for `host`, `srflx`, and `relay`;
   - every `icecandidateerror` with `url`, `errorCode`, and `errorText`;
   - the **selected candidate pair** from `transport.selectedCandidatePairId`, including local and remote candidate types, protocols, RTT, and if present the local candidate `relayProtocol`;
   - inbound RTP stats, especially `packetsReceived`, `bytesReceived`, and `framesDecoded`. citeturn22view0turn23view0turn7view3turn18view1turn7view4turn6search5

3. On the server side, log the answer SDP summary when `webrtc-media.py` applies the remote answer. Then capture your existing two log tails:
```bash
ssh MediaServer2 'sudo /usr/local/bin/docker logs Cloud_Gaming_Player1 2>&1 | grep -E "remote answer applied|ICE:|ice-connection|peer-connection|client ICE|WARN" | tail -50'
ssh MediaServer2 'sudo /usr/local/bin/docker logs RA2_Coturn 2>&1 | tail -50'
```
This matters because half-trickle is valid, so the most important question is not “what came later in trickle?” but “what was already inside the answer SDP when the server applied it?” citeturn4view5turn12view2

4. Read the result like this:
   - **If the answer SDP has `relay=0` or the browser logs `icecandidateerror` 701 against your TURN URL**, the bug is that TURN is not actually being gathered from that client network. Fix TURN reachability and coturn config first. citeturn22view0turn7view0
   - **If the selected pair is relay, but inbound RTP stays at zero**, the browser did obtain TURN and ICE selected it, but media is still not traversing. That points to coturn NAT mapping, relay-port forwarding, or a transport-level issue after allocation. citeturn4view2turn17view0turn7view3turn7view4
   - **If the selected pair is relay and RTP counters or `framesDecoded` rise, but the status still says WSS**, WebRTC transport is working and the remaining bug is in `ultra-play.js` fallback/promotion logic. citeturn7view3turn7view4turn6search5turn7view5

If you want a completely isolated browser-only sanity check after that, the official WebRTC Trickle ICE sample exists specifically to verify whether your TURN URLs yield `relay` candidates from a given client network. citeturn4view7

## Minimal code and config changes

The first code change I would make is **not** a transport rewrite. It is instrumentation, because your next decision depends on whether useful candidates are already in the answer SDP and whether the browser ever selects and uses a relay pair. GStreamer already supports remote descriptions and later trickled candidates; the missing visibility is in your logs, not in ICE theory. citeturn12view2turn4view5

In `container/webrtc-media.py`, add an SDP ICE summarizer and log it when the remote answer is applied:

```diff
+from collections import Counter
+import json
+
+def _summarize_sdp_ice(sdp: str) -> dict:
+    types = Counter()
+    protos = Counter()
+    for raw in sdp.splitlines():
+        line = raw.strip()
+        if not line.startswith("a=candidate:"):
+            continue
+        toks = line[len("a=candidate:"):].split()
+        if len(toks) >= 8:
+            protos[toks[2].lower()] += 1
+            if "typ" in toks:
+                i = toks.index("typ")
+                if i + 1 < len(toks):
+                    types[toks[i + 1].lower()] += 1
+    return {
+        "candidates": sum(types.values()),
+        "types": dict(types),
+        "protocols": dict(protos),
+        "hasIceLite": "a=ice-lite" in sdp,
+    }
...
- log.info("[webrtc] remote answer applied (%d bytes)", len(answer_sdp.encode("utf-8")))
+ ice_summary = _summarize_sdp_ice(answer_sdp)
+ log.info(
+     "[webrtc] remote answer applied (%d bytes, ICE: %s)",
+     len(answer_sdp.encode("utf-8")),
+     json.dumps(ice_summary, sort_keys=True),
+ )
```

In `container/remote-ultra/ultra-play.js`, add a relay-only diagnostic flag, TURN error logging, and selected-pair stats logging:

```diff
+function summarizeSdpIce(sdp) {
+  const out = { host: 0, srflx: 0, relay: 0, prflx: 0 };
+  for (const line of (sdp || "").split(/\r?\n/)) {
+    if (!line.startsWith("a=candidate:")) continue;
+    const m = line.match(/\btyp\s+(host|srflx|relay|prflx)\b/i);
+    if (m) out[m[1].toLowerCase()]++;
+  }
+  return out;
+}
+
+async function logSelectedPair(pc) {
+  const stats = await pc.getStats();
+  let pair = null;
+  for (const r of stats.values()) {
+    if (r.type === "transport" && r.selectedCandidatePairId) {
+      pair = stats.get(r.selectedCandidatePairId);
+      break;
+    }
+  }
+  if (!pair) return;
+  const local = stats.get(pair.localCandidateId);
+  const remote = stats.get(pair.remoteCandidateId);
+  let inbound = null;
+  for (const r of stats.values()) {
+    if (r.type === "inbound-rtp" && r.kind === "video") {
+      inbound = r;
+      break;
+    }
+  }
+  console.info("[ultra-play] selected pair", {
+    state: pair.state,
+    nominated: pair.nominated,
+    rtt: pair.currentRoundTripTime,
+    localType: local?.candidateType,
+    localProtocol: local?.protocol,
+    localRelayProtocol: local?.relayProtocol,
+    remoteType: remote?.candidateType,
+    remoteProtocol: remote?.protocol,
+    packetsReceived: inbound?.packetsReceived,
+    bytesReceived: inbound?.bytesReceived,
+    framesDecoded: inbound?.framesDecoded,
+  });
+}
...
+const relayOnly = new URL(location.href).searchParams.get("relayOnly") === "1";
 const pc = new RTCPeerConnection({
   iceServers,
+  iceTransportPolicy: relayOnly ? "relay" : "all",
 });
+
+pc.addEventListener("icecandidateerror", (e) => {
+  console.warn("[ultra-play] icecandidateerror", {
+    url: e.url,
+    errorCode: e.errorCode,
+    errorText: e.errorText,
+    address: e.address,
+    port: e.port,
+  });
+});
+
+pc.addEventListener("track", (e) => {
+  console.info("[ultra-play] ontrack", {
+    kind: e.track?.kind,
+    streams: e.streams?.length || 0,
+  });
+});
...
- await pc.setRemoteDescription(answer);
+ await pc.setRemoteDescription(answer);
+ console.info("[ultra-play] answer ICE", {
+   ...summarizeSdpIce(answer.sdp),
+   sdpBytes: new TextEncoder().encode(answer.sdp || "").length,
+ });
+ setInterval(() => logSelectedPair(pc).catch(() => {}), 2000);
```

For coturn, the minimal structural correction is to make it **explicitly NAT-aware** and, if you care about hostile remote networks, to add a TLS listener on 443. Coturn says `-X/--external-ip` is needed when the server is behind NAT, and WebRTC-oriented coturn usage should use fingerprints plus long-term credentials. It also supports TCP/TLS listener ports such as 443 for strict NAT or firewall environments. citeturn4view2turn17view2turn17view3turn19view4turn7view1

```diff
# coturn/turnserver.conf

+fingerprint
+lt-cred-mech
+realm=peterjfrancoiii2.synology.me
+user=ra2turn:Ra2TurnRelay2026!

 listening-port=62011
+tls-listening-port=443

+# If the coturn/player shared namespace has an internal Docker IP,
+# use that IP on the private side of external-ip.
+# Do NOT blindly use 192.168.0.193 here unless the container is truly on host networking.
+listening-ip=0.0.0.0
+relay-ip=<TURN_NAMESPACE_IP>
+external-ip=108.2.161.76/<TURN_NAMESPACE_IP>

 min-port=62012
 max-port=62014

+# Needed only if you enable turns:
+cert=/path/to/fullchain.pem
+pkey=/path/to/privkey.pem
```

If you enable `turns:` on 443, publish that TCP port in Compose and add it to the browser `iceServers`. Browsers expect TURN configuration as `urls`, `username`, and `credential`; GStreamer’s own `add-turn-server` uses a different URI form and should not be confused with the browser API. citeturn7view2turn4view0

```diff
# compose.ultra-udp.yaml
 services:
   RA2_Coturn:
     ports:
       - "62011:62011/udp"
       - "62011:62011/tcp"
       - "62012-62014:62012-62014/udp"
+      - "443:443/tcp"
```

```diff
// browser iceServers
[
  {
    urls: [
+     "stun:peterjfrancoiii2.synology.me:62011",
      "turn:peterjfrancoiii2.synology.me:62011?transport=udp",
      "turn:peterjfrancoiii2.synology.me:62011?transport=tcp",
+     "turns:peterjfrancoiii2.synology.me:443?transport=tcp",
    ],
    username: "ra2turn",
    credential: "Ra2TurnRelay2026!",
  }
]
```

A small but important note on the relay port range: your current `62012–62014` range can work for a **single-session** diagnostic, but coturn’s default relay range is much larger. If you later see coturn allocation-capacity errors or want concurrency, widen that range; do not change it preemptively unless the logs tell you to. citeturn19view0turn19view2

## TURN verdict and fallback recommendation

Your TURN setup is **close**, but I would not call it “proven correct” yet. The open question is still the decisive one: **does the browser’s answer SDP, on an actually failing remote network, contain `typ relay`, and does the selected browser-side candidate pair use that relay path?** Until that is logged, the current data only proves that TURN is *reachable enough to probe*, not that it is *working as the browser’s chosen media path*. citeturn7view0turn7view3turn23view0

On the configuration itself, I would make three judgments. First, **sharing the player network namespace is fine**; that is not a problem by itself. Second, because the NAS still sits behind your home router, **`external-ip` is still required** for coturn if it is behind NAT. Third, **port 62011 is valid but not universal**. If you want this to work for remote browsers on ordinary home and mobile networks, home-hosted coturn with correct `external-ip` is probably enough. If you want it to survive schools, hotels, offices, and some guest Wi‑Fi environments, add `turns:` on **TCP 443**. citeturn4view2turn17view0turn19view4turn7view1

I would **not** pursue ICE-TCP-only as the main fallback. The WebRTC transport spec says ICE-TCP must be supported, but it also explains that for UDP-blocking firewalls, the important path is TURN over TCP or TLS-to-TURN, often still yielding UDP relay candidates toward the peer; TURN TCP candidates themselves are of limited benefit and can perform worse because of head-of-line blocking. So the right fallback order is: direct UDP if possible, then TURN relay, ideally with UDP first and TCP/TLS to the TURN server when needed. citeturn7view1

If, after the relay-only experiment and the `external-ip` fix, you still cannot get reliable relay candidates from some remote networks, then the decision becomes operational rather than theoretical. If low latency matters, the best fallback is **hosted TURN** on a public VPS or managed TURN service with `turns:` on 443, while keeping your NAS as the media origin. WebRTC’s own guidance treats both self-hosted coturn and cloud TURN as normal options. If you do **not** want to run TURN on 443 anywhere, then you should assume some remote networks will never do UDP/WebRTC reliably and accept **WSS-only fallback** on those networks as a product decision rather than a bug. citeturn7view0turn21search11turn7view1

The practical priority order I would use is therefore simple: **log answer-SDP ICE counts, run one relay-only remote attempt, fix coturn `external-ip`, add `turns:443`, and only then revisit any UI fallback logic**. Based on the standards and the symptoms you reported, that is the shortest path to a real root-cause answer and the highest-probability path to getting `Video: WebRTC/...` for remote browsers outside the home LAN. citeturn4view5turn4view2turn7view1turn7view3turn7view4