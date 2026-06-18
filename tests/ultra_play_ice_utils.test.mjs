import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const Ice = require(join(here, "../container/remote-ultra/webrtc-ice-utils.js"));

const MDNS_SDP = [
  "v=0",
  "a=candidate:1 1 udp 2122260223 abcdef.local 54321 typ host generation 0",
  "a=candidate:2 1 udp 2122260223 fedcba.local 54322 typ host generation 0",
].join("\n");

const HOST_SDP = [
  "v=0",
  "a=candidate:1 1 udp 2122260223 192.168.0.50 54321 typ host generation 0",
].join("\n");

test("sdpHasUsableLocalIce rejects mDNS-only SDP", () => {
  assert.equal(Ice.sdpHasUsableLocalIce(MDNS_SDP), false);
  assert.equal(Ice.sdpHasUsableLocalIce(HOST_SDP), true);
});

test("replaceMdnsWithIpInSdp rewrites host lines to LAN IP", () => {
  const out = Ice.replaceMdnsWithIpInSdp(MDNS_SDP, "192.168.0.50");
  assert.match(out, /192\.168\.0\.50 54321/);
  assert.doesNotMatch(out, /\.local/);
  assert.equal(Ice.sdpHasUsableLocalIce(out), true);
});

test("sanitizeAnswerSdpForServer strips mDNS without IP replacement", () => {
  const out = Ice.sanitizeAnswerSdpForServer(MDNS_SDP);
  assert.equal(Ice.summarizeSdpIce(out).candidates, 0);
});

test("rewriteTurnUrlsForLan swaps DDNS for page hostname", () => {
  const servers = [
    {
      urls: "turn:peterjfrancoiii2.synology.me:62011?transport=udp",
      username: "ra2turn",
      credential: "secret",
    },
  ];
  const out = Ice.rewriteTurnUrlsForLan(servers, "192.168.0.193");
  const url = Array.isArray(out[0].urls) ? out[0].urls[0] : out[0].urls;
  assert.match(url, /192\.168\.0\.193:62011/);
});

test("extractLanIpFromGatheredLines prefers private LAN address", () => {
  const ip = Ice.extractLanIpFromGatheredLines([
    "candidate:1 1 udp 1853824767 108.2.161.76 54321 typ srflx raddr 192.168.0.88 rport 54321 generation 0",
  ]);
  assert.equal(ip, "192.168.0.88");
});

test("localCandidateLinesFromSdp omits mDNS lines", () => {
  const mixed = Ice.replaceMdnsWithIpInSdp(MDNS_SDP, "192.168.0.50");
  const lines = Ice.localCandidateLinesFromSdp(mixed);
  assert.equal(lines.length, 2);
  assert.ok(lines.every((line) => !line.includes(".local")));
});

test("isRemotePlayPage detects DDNS hostname", () => {
  assert.equal(Ice.isRemotePlayPage("peterjfrancoiii2.synology.me"), true);
  assert.equal(Ice.isRemotePlayPage("192.168.0.193"), false);
});

test("orderIceServersForRemote prefers TURN TCP then UDP and skips TURNS", () => {
  const servers = [
    { urls: "turn:example.synology.me:62011?transport=udp", username: "u", credential: "p" },
    { urls: "stun:stun.l.google.com:19302" },
    { urls: "turns:example.synology.me:5349?transport=tcp", username: "u", credential: "p" },
    { urls: "turn:example.synology.me:62011?transport=tcp", username: "u", credential: "p" },
  ];
  const out = Ice.orderIceServersForRemote(servers, "example.synology.me");
  assert.match(Ice.iceServerUrl(out[0]), /transport=tcp/);
  assert.match(Ice.iceServerUrl(out[1]), /transport=udp/);
  assert.equal(out.some((e) => Ice.iceServerUrl(e).startsWith("turns:")), false);
});

test("turnServersForRemotePlay returns credentialed plain TURN only", () => {
  const servers = [
    { urls: "stun:stun.l.google.com:19302" },
    { urls: "turns:example.synology.me:5349", username: "u", credential: "p" },
    { urls: "turn:example.synology.me:62011?transport=tcp", username: "u", credential: "p" },
  ];
  const out = Ice.turnServersForRemotePlay(servers);
  assert.equal(out.length, 1);
  assert.match(Ice.iceServerUrl(out[0]), /^turn:/);
});

test("sdpHasRelayIce detects relay candidates", () => {
  const sdp = "v=0\na=candidate:1 1 udp 123 1.2.3.4 62017 typ relay generation 0\n";
  assert.equal(Ice.sdpHasRelayIce(sdp), true);
  assert.equal(Ice.sdpHasRelayIce(HOST_SDP), false);
});

test("shouldUseRelayIcePolicy only when explicitly relay-only", () => {
  assert.equal(
    Ice.shouldUseRelayIcePolicy({ relayOnlyDiagnostic: false, webrtcForceRelayOnly: false }),
    false,
  );
  assert.equal(
    Ice.shouldUseRelayIcePolicy({ relayOnlyDiagnostic: true, webrtcForceRelayOnly: false }),
    true,
  );
  assert.equal(
    Ice.shouldUseRelayIcePolicy({ relayOnlyDiagnostic: false, webrtcForceRelayOnly: true }),
    true,
  );
});

test("shouldUseRelayIcePolicy enables relay for remote DDNS with TURN", () => {
  assert.equal(
    Ice.shouldUseRelayIcePolicy({
      preferRelayOnRemote: true,
      hasTurnServers: true,
    }),
    true,
  );
  assert.equal(
    Ice.shouldUseRelayIcePolicy({
      preferRelayOnRemote: true,
      hasTurnServers: false,
    }),
    false,
  );
});

test("shouldUseRelayIcePolicy ignores remote DDNS alone", () => {
  assert.equal(
    Ice.shouldUseRelayIcePolicy({
      relayOnlyDiagnostic: false,
      webrtcForceRelayOnly: false,
      isRemotePlayPage: true,
    }),
    false,
  );
});

test("shouldAttemptRemoteRelayRetry skips no TURN relay errors", () => {
  assert.equal(
    Ice.shouldAttemptRemoteRelayRetry({
      reason: "no TURN relay candidate (check icecandidateerror)",
      relayReconnectAttempted: false,
      relayOnlyDiagnostic: false,
      isRemotePlayPage: true,
      hasTurnServers: true,
    }),
    false,
  );
});

test("shouldAttemptRemoteRelayRetry on ICE failure over DDNS", () => {
  assert.equal(
    Ice.shouldAttemptRemoteRelayRetry({
      reason: "ICE failed (connectivity checks failed)",
      relayReconnectAttempted: false,
      relayOnlyDiagnostic: false,
      isRemotePlayPage: true,
      hasTurnServers: true,
    }),
    true,
  );
  assert.equal(
    Ice.shouldAttemptRemoteRelayRetry({
      reason: "UDP signaling failed: x",
      isRemotePlayPage: true,
      hasTurnServers: true,
    }),
    false,
  );
  assert.equal(
    Ice.shouldAttemptRemoteRelayRetry({
      reason: "ICE failed",
      relayReconnectAttempted: true,
      isRemotePlayPage: true,
      hasTurnServers: true,
    }),
    false,
  );
});

test("validateCoturnRelayPorts rejects player2 docker-proxy overlap", () => {
  const bad = Ice.validateCoturnRelayPorts({
    relayMin: 62031,
    relayMax: 62040,
    turnListenPort: 62011,
    player1UdpMin: 62001,
    player1UdpMax: 62020,
    player2UdpMin: 62021,
    player2UdpMax: 62040,
  });
  assert.equal(bad.ok, false);
  assert.match(bad.errors.join(" "), /overlaps player2/);
});

test("validateCoturnRelayPorts accepts player1 relay range 62012-62020", () => {
  const ok = Ice.validateCoturnRelayPorts({
    relayMin: 62012,
    relayMax: 62020,
    turnListenPort: 62011,
    player1UdpMin: 62001,
    player1UdpMax: 62020,
    player2UdpMin: 62021,
    player2UdpMax: 62040,
  });
  assert.equal(ok.ok, true, ok.errors.join("; "));
});

test("validateCoturnRelayPorts matches repo turnserver.conf", () => {
  const fs = require("node:fs");
  const conf = fs.readFileSync(join(here, "../coturn/turnserver.conf"), "utf8");
  const min = Number(conf.match(/^min-port=(\d+)/m)[1]);
  const max = Number(conf.match(/^max-port=(\d+)/m)[1]);
  const listen = Number(conf.match(/^listening-port=(\d+)/m)[1]);
  const result = Ice.validateCoturnRelayPorts({
    relayMin: min,
    relayMax: max,
    turnListenPort: listen,
    player1UdpMin: 62001,
    player1UdpMax: 62020,
    player2UdpMin: 62021,
    player2UdpMax: 62040,
  });
  assert.equal(result.ok, true, result.errors.join("; "));
});

test("isRtpSustained requires consecutive growth", () => {
  let streak = 0;
  let prev = 0;
  let r = Ice.isRtpSustained(prev, 5, streak);
  assert.equal(r.sustained, false);
  streak = r.growthStreak;
  prev = 5;
  r = Ice.isRtpSustained(prev, 12, streak);
  assert.equal(r.sustained, true);
  assert.equal(r.growthStreak, 2);
});

test("shouldFallbackForStall skips when RTP still growing", () => {
  const now = 10000;
  assert.equal(
    Ice.shouldFallbackForStall({
      lastProgressAt: 1000,
      now,
      stallMs: 3000,
      rtpGrowing: true,
    }),
    false,
  );
  assert.equal(
    Ice.shouldFallbackForStall({
      lastProgressAt: 1000,
      now,
      stallMs: 3000,
      rtpGrowing: false,
    }),
    true,
  );
});

test("stallGraceMs is longer on remote", () => {
  assert.equal(Ice.stallGraceMs(false), 3000);
  assert.equal(Ice.stallGraceMs(true), 12000);
});

test("disconnectGraceMs is longer on remote", () => {
  assert.equal(Ice.disconnectGraceMs(false), 4000);
  assert.equal(Ice.disconnectGraceMs(true), 30000);
});

test("isUdpMediaVerified requires sustained RTP on remote", () => {
  assert.equal(
    Ice.isUdpMediaVerified({ isRemote: true, framesReceived: 30, packets: 40 }),
    false,
  );
  assert.equal(
    Ice.isUdpMediaVerified({ isRemote: true, framesDecoded: 1 }),
    true,
  );
  assert.equal(
    Ice.isUdpMediaVerified({ isRemote: true, rtpSustained: true }),
    true,
  );
});

test("shouldFallbackOnConnectionDisconnect ignores transient disconnect with live ICE", () => {
  assert.equal(
    Ice.shouldFallbackOnConnectionDisconnect({
      videoActive: true,
      iceConnectionState: "connected",
      rtpRecent: false,
    }),
    false,
  );
  assert.equal(
    Ice.shouldFallbackOnConnectionDisconnect({
      videoActive: true,
      iceConnectionState: "disconnected",
      rtpRecent: true,
    }),
    false,
  );
});

test("gatheredLinesHaveUsableIce detects trickle srflx not in SDP", () => {
  const lines = [
    "candidate:1 1 udp 1853824767 192.168.0.32 52923 typ srflx raddr 0.0.0.0 rport 0 generation 0",
  ];
  assert.equal(Ice.gatheredLinesHaveUsableIce(lines), true);
  assert.equal(Ice.hasUsableIce({ sdp: "v=0\n", gatheredLines: lines }), true);
});

test("embedCandidateLinesInSdp adds gathered trickle lines", () => {
  const sdp = "v=0\no=- 0 0 IN IP4 127.0.0.1\n";
  const lines = [
    "candidate:1 1 udp 1853824767 108.2.161.76 62017 typ relay raddr 0.0.0.0 rport 0 generation 0",
  ];
  const out = Ice.embedCandidateLinesInSdp(sdp, lines);
  assert.match(out, /typ relay/);
  assert.equal(Ice.sdpHasUsableLocalIce(out), true);
});

test("shouldSendEndOfCandidates requires useful trickle", () => {
  assert.equal(Ice.shouldSendEndOfCandidates(false), false);
  assert.equal(Ice.shouldSendEndOfCandidates(true), true);
});

test("buildFastAnswerSdp embeds gathered relay lines", () => {
  const sdp = "v=0\n";
  const lines = [
    "candidate:1 1 udp 123 108.2.161.76 62017 typ relay generation 0",
  ];
  const out = Ice.buildFastAnswerSdp(sdp, lines);
  assert.equal(Ice.sdpHasUsableLocalIce(out), true);
});

test("fallbackReasonAllowsRelayRetry includes ICE gather signaling errors", () => {
  assert.equal(Ice.fallbackReasonAllowsRelayRetry("no reachable ICE candidate for server"), true);
  assert.equal(Ice.fallbackReasonAllowsRelayRetry("refusing empty end-of-candidates"), true);
  assert.equal(Ice.fallbackReasonAllowsRelayRetry("UDP signaling socket closed before answer"), true);
});

test("shouldScheduleTrickleEndOfCandidates defers during early trickle", () => {
  assert.equal(
    Ice.shouldScheduleTrickleEndOfCandidates({ earlyTrickleActive: true, answerSent: true }),
    false,
  );
  assert.equal(
    Ice.shouldScheduleTrickleEndOfCandidates({ earlyTrickleActive: false, answerSent: true }),
    true,
  );
  assert.equal(
    Ice.shouldScheduleTrickleEndOfCandidates({ earlyTrickleActive: false, answerSent: false }),
    false,
  );
});
