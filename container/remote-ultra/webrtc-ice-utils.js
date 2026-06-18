/**
 * Pure WebRTC ICE helpers for ultra-play (browser + node unit tests).
 */
(function (root) {
  function isLanHostname(hostname) {
    const host = String(hostname || "");
    return (
      /^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)/.test(host) ||
      host === "localhost" ||
      host === "127.0.0.1"
    );
  }

  function isTurnIceEntry(entry) {
    const url = String(entry?.urls || "");
    return (
      (url.startsWith("turn:") || url.startsWith("turns:")) && entry.username && entry.credential
    );
  }

  function isRemotePlayPage(hostname) {
    return !isLanHostname(hostname);
  }

  function iceServerUrl(entry) {
    const urls = entry?.urls;
    return String(Array.isArray(urls) ? urls[0] : urls || "");
  }

  /** VPN/DDNS: prefer TURN TCP then UDP; skip TURNS (broken self-signed TLS on NAS). */
  function orderIceServersForRemote(servers, hostname) {
    if (isLanHostname(hostname)) return servers;
    const turnTcp = [];
    const turnUdp = [];
    const turnOther = [];
    const stun = [];
    const other = [];
    for (const entry of servers || []) {
      const url = iceServerUrl(entry);
      if (url.startsWith("turns:")) continue;
      if (url.startsWith("turn:")) {
        if (url.includes("transport=tcp")) turnTcp.push(entry);
        else if (url.includes("transport=udp")) turnUdp.push(entry);
        else turnOther.push(entry);
      } else if (url.startsWith("stun:")) stun.push(entry);
      else other.push(entry);
    }
    return [...turnTcp, ...turnUdp, ...turnOther, ...stun, ...other];
  }

  /** Remote WebRTC: credentialed plain TURN only (no TURNS/STUN). */
  function turnServersForRemotePlay(servers) {
    return (servers || []).filter((entry) => {
      const url = iceServerUrl(entry);
      return url.startsWith("turn:") && isTurnIceEntry(entry);
    });
  }

  /** Remote relay play: TURN entries only (no STUN). */
  function iceServersForRelayPlay(servers) {
    return (servers || []).filter((entry) => {
      const url = iceServerUrl(entry);
      return url.startsWith("turn:") || url.startsWith("turns:");
    });
  }

  function sdpHasRelayIce(sdp) {
    return /\btyp relay\b/.test(String(sdp || ""));
  }

  function rewriteTurnUrlsForLan(servers, hostname) {
    if (!isLanHostname(hostname)) return servers;
    const lan = String(hostname || "");
    return (servers || []).map((entry) => {
      if (!isTurnIceEntry(entry)) return entry;
      const urls = Array.isArray(entry.urls) ? entry.urls : [entry.urls];
      return {
        ...entry,
        urls: urls.map((raw) =>
          String(raw || "").replace(
            /[a-z0-9.-]+\.synology\.me|\d{1,3}(?:\.\d{1,3}){3}/gi,
            lan,
          ),
        ),
      };
    });
  }

  function summarizeSdpIce(sdp) {
    const out = { host: 0, srflx: 0, relay: 0, prflx: 0, candidates: 0 };
    for (const line of String(sdp || "").split(/\r?\n/)) {
      if (!line.startsWith("a=candidate:")) continue;
      out.candidates += 1;
      const match = line.match(/\btyp\s+(host|srflx|relay|prflx)\b/i);
      if (match) out[match[1].toLowerCase()] += 1;
    }
    return out;
  }

  function sdpHasUsableLocalIce(sdp) {
    if (!sdp) return false;
    if (/\btyp srflx\b/.test(sdp)) return true;
    if (/\btyp relay\b/.test(sdp)) return true;
    for (const line of String(sdp).split(/\r?\n/)) {
      if (!line.includes("a=candidate:")) continue;
      if (/\btyp host\b/.test(line) && !/\.local\b/.test(line)) return true;
    }
    return false;
  }

  function isUsableCandidateLine(line) {
    const text = String(line || "");
    if (!text) return false;
    if (/\btyp srflx\b/.test(text) || /\btyp relay\b/.test(text)) return true;
    if (/\btyp host\b/.test(text) && !/\.local\b/.test(text)) return true;
    return false;
  }

  function gatheredLinesHaveUsableIce(lines) {
    return (lines || []).some((line) => isUsableCandidateLine(line));
  }

  function gatheredLinesHaveRelay(lines) {
    return (lines || []).some((line) => /\btyp relay\b/.test(String(line || "")));
  }

  function hasUsableIce({ sdp, gatheredLines }) {
    return sdpHasUsableLocalIce(sdp) || gatheredLinesHaveUsableIce(gatheredLines);
  }

  function embedCandidateLinesInSdp(sdp, lines) {
    if (!sdp || !lines?.length) return sdp || "";
    const ending = String(sdp).includes("\r\n") ? "\r\n" : "\n";
    const existing = new Set(
      String(sdp)
        .split(/\r?\n/)
        .filter((line) => line.startsWith("a=candidate:"))
        .map((line) => line.trim()),
    );
    const additions = [];
    for (const raw of lines) {
      const trimmed = String(raw || "").trim();
      if (!trimmed) continue;
      const line = trimmed.startsWith("a=candidate:")
        ? trimmed
        : `a=candidate:${trimmed}`;
      if (!isUsableCandidateLine(line)) continue;
      if (existing.has(line)) continue;
      existing.add(line);
      additions.push(line);
    }
    if (!additions.length) return sdp;
    const base = String(sdp).replace(/\r?\n$/, "");
    return `${base}${ending}${additions.join(ending)}${ending}`;
  }

  function shouldSendEndOfCandidates(usefulCandidateSent) {
    return Boolean(usefulCandidateSent);
  }

  /** Cap how long remote answer SDP may wait before the server times out. */
  function remoteAnswerGatherDeadlineMs(remoteMs = 15000, lanMs = 1500) {
    return remoteMs;
  }

  function buildFastAnswerSdp(baseSdp, gatheredLines) {
    let sdp = sanitizeAnswerSdpForServer(baseSdp || "");
    return embedCandidateLinesInSdp(sdp, gatheredLines);
  }

  function sanitizeAnswerSdpForServer(sdp) {
    if (!sdp) return sdp;
    const lines = String(sdp).split(/\r?\n/).filter((line) => {
      if (!line.includes("a=candidate:")) return true;
      return !(/\.local\b/.test(line) && /\btyp host\b/.test(line));
    });
    const ending = sdp.includes("\r\n") ? "\r\n" : "\n";
    let body = lines.join(ending);
    if (sdp.endsWith(ending)) body += ending;
    return body;
  }

  function replaceMdnsWithIpInSdp(sdp, hostIp) {
    if (!sdp || !hostIp) return sdp;
    return String(sdp)
      .split(/\r?\n/)
      .map((line) => {
        if (!line.includes("a=candidate:") || !/\.local\b/.test(line)) return line;
        if (!/\btyp host\b/.test(line)) return line;
        return line.replace(/(\ba=candidate:\S+\s+\d+\s+\w+\s+\d+\s+)[^\s]+(\s+\d+)/, `$1${hostIp}$2`);
      })
      .join("\n");
  }

  function localCandidateLinesFromSdp(sdp) {
    if (!sdp) return [];
    return String(sdp)
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line.startsWith("a=candidate:") && !/\.local\b/.test(line))
      .map((line) => line.replace(/^a=candidate:/, ""));
  }

  function extractLanIpFromGatheredLines(lines) {
    const ips = [];
    for (const raw of lines || []) {
      const parts = String(raw).split(/\s+/);
      if (parts.length > 7 && parts[7] === "srflx" && /^\d+\.\d+\.\d+\.\d+$/.test(parts[4])) {
        ips.push(parts[4]);
      }
      const raddrIdx = parts.indexOf("raddr");
      if (raddrIdx >= 0 && /^\d+\.\d+\.\d+\.\d+$/.test(parts[raddrIdx + 1] || "")) {
        ips.push(parts[raddrIdx + 1]);
      }
    }
    const lan = ips.find((ip) => ip.startsWith("192.168.") || ip.startsWith("10."));
    return lan || ips[0] || "";
  }

  function normalizeStatsCandidateLine(line, report) {
    if (!line) return "";
    const ip = report.address || report.ipAddress || report.ip || "";
    if (ip && !ip.includes(":") && /\.local\b/.test(line)) {
      return line.replace(/(\s)\S+\.local(\s+)/, `$1${ip}$2`);
    }
    if (/\btyp host\b/.test(line) && /\.local\b/.test(line)) return "";
    return line;
  }

  /** Relay-only ICE when ?relayOnly=1 diagnostic or forced relay retry — not default remote. */
  function shouldUseRelayIcePolicy(opts = {}) {
    return Boolean(
      opts.relayOnlyDiagnostic ||
        opts.webrtcForceRelayOnly ||
        (opts.preferRelayOnRemote && opts.hasTurnServers),
    );
  }

  function fallbackReasonAllowsRelayRetry(reason) {
    if (!reason) return false;
    return /ICE|timed out|connection failed|never confirmed|connectivity|video stalled|video lost|no reachable ICE|end-of-candidates|signaling socket closed|mDNS-only|trickle timeout/i.test(
      String(reason),
    );
  }

  function shouldAttemptRemoteRelayRetry(ctx = {}) {
    if (ctx.reason && /no TURN relay/i.test(String(ctx.reason))) {
      return false;
    }
    return Boolean(
      ctx.allowRelayRetry !== false &&
        fallbackReasonAllowsRelayRetry(ctx.reason) &&
        !ctx.relayReconnectAttempted &&
        !ctx.relayOnlyDiagnostic &&
        ctx.isRemotePlayPage &&
        ctx.hasTurnServers,
    );
  }

  function portRangesOverlap(minA, maxA, minB, maxB) {
    return Number(minA) <= Number(maxB) && Number(minB) <= Number(maxA);
  }

  /** Guard coturn relay ports vs player1 router forward + player2 docker-proxy publish. */
  function validateCoturnRelayPorts(cfg = {}) {
    const errors = [];
    const relayMin = Number(cfg.relayMin);
    const relayMax = Number(cfg.relayMax);
    const turnListenPort = Number(cfg.turnListenPort);
    const player1UdpMin = Number(cfg.player1UdpMin);
    const player1UdpMax = Number(cfg.player1UdpMax);
    const player2UdpMin = Number(cfg.player2UdpMin);
    const player2UdpMax = Number(cfg.player2UdpMax);
    if (relayMin > relayMax) {
      errors.push(`coturn relay min ${relayMin} > max ${relayMax}`);
    }
    if (portRangesOverlap(relayMin, relayMax, player2UdpMin, player2UdpMax)) {
      errors.push(
        `coturn relay ${relayMin}-${relayMax} overlaps player2 publish ${player2UdpMin}-${player2UdpMax} (docker-proxy blocks relay bind)`,
      );
    }
    if (turnListenPort >= relayMin && turnListenPort <= relayMax) {
      errors.push(`TURN listen port ${turnListenPort} must not be inside relay range`);
    }
    if (relayMin < player1UdpMin || relayMax > player1UdpMax) {
      errors.push(
        `coturn relay ${relayMin}-${relayMax} outside player1 router forward ${player1UdpMin}-${player1UdpMax}`,
      );
    }
    return { ok: errors.length === 0, errors };
  }

  /** Require consecutive RTP growth before treating UDP as verified. */
  function isRtpSustained(previousPackets, currentPackets, growthStreak, options = {}) {
    const minStreak = options.minStreak ?? 2;
    const minPackets = options.minPackets ?? 8;
    const prev = Number(previousPackets || 0);
    const cur = Number(currentPackets || 0);
    const growing = cur > prev;
    const streak = growing ? growthStreak + 1 : cur > 0 ? 0 : growthStreak;
    return {
      sustained: streak >= minStreak && cur >= minPackets,
      growthStreak: streak,
    };
  }

  function stallGraceMs(isRemote, lanMs = 3000, remoteMs = 12000) {
    return isRemote ? remoteMs : lanMs;
  }

  function disconnectGraceMs(isRemote, lanMs = 4000, remoteMs = 30000) {
    return isRemote ? remoteMs : lanMs;
  }

  /** Remote play needs decoded frames or sustained RTP — not a single burst. */
  function isUdpMediaVerified(stats = {}) {
    const framesDecoded = Number(stats.framesDecoded || 0);
    const framesReceived = Number(stats.framesReceived || 0);
    const packets = Number(stats.packets || 0);
    const rtpSustained = Boolean(stats.rtpSustained);
    if (stats.isRemote) {
      return framesDecoded > 0 || rtpSustained;
    }
    return (
      framesDecoded > 0 ||
      rtpSustained ||
      (framesReceived > 15 && packets > 20)
    );
  }

  function shouldFallbackOnConnectionDisconnect(ctx = {}) {
    if (!ctx.videoActive) return false;
    const ice = String(ctx.iceConnectionState || "");
    if (ice === "connected" || ice === "completed") return false;
    if (ctx.rtpRecent) return false;
    return true;
  }

  function shouldFallbackForStall({ lastProgressAt, now, stallMs, rtpGrowing }) {
    if (!lastProgressAt || rtpGrowing) return false;
    return now - lastProgressAt > stallMs;
  }

  /** Early-trickle mode owns end-of-candidates; onicecandidate null must not race ahead. */
  function shouldScheduleTrickleEndOfCandidates({ earlyTrickleActive, answerSent }) {
    return Boolean(answerSent && !earlyTrickleActive);
  }

  const api = {
    isLanHostname,
    isRemotePlayPage,
    isTurnIceEntry,
    iceServerUrl,
    orderIceServersForRemote,
    sdpHasRelayIce,
    shouldUseRelayIcePolicy,
    fallbackReasonAllowsRelayRetry,
    shouldAttemptRemoteRelayRetry,
    portRangesOverlap,
    validateCoturnRelayPorts,
    isRtpSustained,
    stallGraceMs,
    disconnectGraceMs,
    isUdpMediaVerified,
    shouldFallbackOnConnectionDisconnect,
    shouldFallbackForStall,
    shouldScheduleTrickleEndOfCandidates,
    isUsableCandidateLine,
    gatheredLinesHaveUsableIce,
    gatheredLinesHaveRelay,
    hasUsableIce,
    embedCandidateLinesInSdp,
    shouldSendEndOfCandidates,
    remoteAnswerGatherDeadlineMs,
    buildFastAnswerSdp,
    iceServersForRelayPlay,
    turnServersForRemotePlay,
    rewriteTurnUrlsForLan,
    summarizeSdpIce,
    sdpHasUsableLocalIce,
    sanitizeAnswerSdpForServer,
    replaceMdnsWithIpInSdp,
    localCandidateLinesFromSdp,
    extractLanIpFromGatheredLines,
    normalizeStatsCandidateLine,
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
  root.Ra2WebRtcIceUtils = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
