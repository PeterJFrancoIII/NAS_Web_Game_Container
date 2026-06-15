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

  const api = {
    isLanHostname,
    isTurnIceEntry,
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
