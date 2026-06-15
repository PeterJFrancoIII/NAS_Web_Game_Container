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
