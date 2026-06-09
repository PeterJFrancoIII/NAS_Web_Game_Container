(() => {
  const params = new URLSearchParams(window.location.search);
  const probeIntervalMs = Number(params.get("latency_probe_ms") || "0");
  const historyLimit = 30;
  const samples = [];
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  let socket = null;
  let timer = null;

  function tokenPath(token) {
    const url = new URL(window.location.href);
    url.protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    url.search = "";
    url.hash = "";
    const basePath = url.pathname.replace(/\/[^/]*$/, "/websockify");
    url.pathname = basePath;
    url.searchParams.set("token", token);
    return url.toString();
  }

  function fmt(value) {
    return Number.isFinite(value) ? `${Math.round(value)} ms` : "--";
  }

  function stats() {
    if (samples.length === 0) {
      return { last: NaN, min: NaN, avg: NaN, max: NaN };
    }
    const sum = samples.reduce((acc, sample) => acc + sample, 0);
    return {
      last: samples[samples.length - 1],
      min: Math.min(...samples),
      avg: sum / samples.length,
      max: Math.max(...samples),
    };
  }

  function presetUrl(changes) {
    const next = new URL(window.location.href);
    const nextParams = next.searchParams;
    for (const [key, value] of Object.entries(changes)) {
      nextParams.set(key, value);
    }
    return next.toString();
  }

  function currentSetting(name, fallback) {
    return params.get(name) || localStorage.getItem(`novnc:${name}`) || fallback;
  }

  function render(panel, status) {
    const s = stats();
    const compression = currentSetting("compression", "default");
    const quality = currentSetting("quality", "default");
    panel.querySelector("[data-latency-status]").textContent = status;
    panel.querySelector("[data-latency-last]").textContent = fmt(s.last);
    panel.querySelector("[data-latency-min]").textContent = fmt(s.min);
    panel.querySelector("[data-latency-avg]").textContent = fmt(s.avg);
    panel.querySelector("[data-latency-max]").textContent = fmt(s.max);
    panel.querySelector("[data-current-settings]").textContent =
      `compression=${compression}, quality=${quality}, resize=${currentSetting("resize", "default")}`;
  }

  function createPanel() {
    const panel = document.createElement("section");
    panel.id = "ra2_latency_overlay";
    panel.innerHTML = `
      <style>
        #ra2_latency_overlay {
          position: fixed;
          right: 12px;
          bottom: 12px;
          z-index: 10000;
          width: 290px;
          padding: 10px 12px;
          color: #f4f4f4;
          background: rgba(14, 18, 24, 0.88);
          border: 1px solid rgba(255,255,255,0.22);
          border-radius: 8px;
          font: 12px/1.35 system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          box-shadow: 0 8px 22px rgba(0,0,0,0.35);
        }
        #ra2_latency_overlay header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 8px;
          margin-bottom: 6px;
          font-weight: 700;
        }
        #ra2_latency_overlay button,
        #ra2_latency_overlay a {
          color: #9bd3ff;
          background: transparent;
          border: 0;
          padding: 0;
          font: inherit;
          text-decoration: underline;
          cursor: pointer;
        }
        #ra2_latency_overlay dl {
          display: grid;
          grid-template-columns: 1fr auto;
          gap: 3px 10px;
          margin: 0 0 7px;
        }
        #ra2_latency_overlay dt { color: #b8c4d0; }
        #ra2_latency_overlay dd { margin: 0; font-variant-numeric: tabular-nums; }
        #ra2_latency_overlay .muted { color: #b8c4d0; }
        #ra2_latency_overlay .presets {
          display: flex;
          gap: 10px;
          margin-top: 7px;
        }
        #ra2_latency_overlay.collapsed dl,
        #ra2_latency_overlay.collapsed .details { display: none; }
      </style>
      <header>
        <span>Latency</span>
        <button type="button" data-toggle-latency>hide</button>
      </header>
      <dl>
        <dt>Probe RTT</dt><dd data-latency-last>--</dd>
        <dt>Min / Avg / Max</dt><dd><span data-latency-min>--</span> / <span data-latency-avg>--</span> / <span data-latency-max>--</span></dd>
        <dt>Probe interval</dt><dd>${probeIntervalMs > 0 ? `${Math.round(probeIntervalMs)} ms` : "manual"}</dd>
        <dt>Status</dt><dd data-latency-status>starting</dd>
      </dl>
      <div class="details">
        <div class="muted" data-current-settings></div>
        <div class="presets">
          <button type="button" data-probe-now>probe now</button>
          <a data-low-preset>lowest latency</a>
          <a data-balanced-preset>balanced</a>
          <a href="#settings">settings</a>
        </div>
      </div>
    `;

    panel.querySelector("[data-toggle-latency]").addEventListener("click", (event) => {
      panel.classList.toggle("collapsed");
      event.currentTarget.textContent = panel.classList.contains("collapsed") ? "show" : "hide";
    });
    panel.querySelector("[data-probe-now]").addEventListener("click", () => sendProbe(panel));
    panel.querySelector("[data-low-preset]").href = presetUrl({
      compression: "0",
      quality: "4",
      resize: "remote",
      autoconnect: "1",
    });
    panel.querySelector("[data-balanced-preset]").href = presetUrl({
      compression: "6",
      quality: "6",
      resize: "remote",
      autoconnect: "1",
    });

    document.body.appendChild(panel);
    render(panel, "starting");
    return panel;
  }

  function sendProbe(panel) {
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      return;
    }
    const now = Date.now();
    socket.send(encoder.encode(`PING:${now}\n`));
    render(panel, "probing");
  }

  async function messageText(data) {
    if (typeof data === "string") {
      return data;
    }
    if (data instanceof ArrayBuffer) {
      return decoder.decode(new Uint8Array(data));
    }
    if (data instanceof Blob) {
      return decoder.decode(new Uint8Array(await data.arrayBuffer()));
    }
    return "";
  }

  function startLatencyProbe(panel) {
    socket = new WebSocket(tokenPath("latency"));
    socket.addEventListener("open", () => {
      render(panel, "connected");
      sendProbe(panel);
      if (probeIntervalMs > 0) {
        timer = window.setInterval(() => sendProbe(panel), Math.max(1000, probeIntervalMs));
      }
    });
    socket.addEventListener("message", async (event) => {
      const message = (await messageText(event.data)).trim();
      if (!message.startsWith("PONG:")) {
        return;
      }
      const [, sent] = message.split(":");
      const rtt = Date.now() - Number(sent);
      if (Number.isFinite(rtt) && rtt >= 0) {
        samples.push(rtt);
        while (samples.length > historyLimit) {
          samples.shift();
        }
      }
      render(panel, "connected");
    });
    socket.addEventListener("close", () => {
      if (timer) {
        window.clearInterval(timer);
        timer = null;
      }
      render(panel, "disconnected");
      window.setTimeout(() => startLatencyProbe(panel), 2000);
    });
    socket.addEventListener("error", () => render(panel, "probe error"));
  }

  window.addEventListener("DOMContentLoaded", () => {
    const panel = createPanel();
    startLatencyProbe(panel);
  });
})();
