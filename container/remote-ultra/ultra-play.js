(() => {
  "use strict";

  const SETTINGS_KEY = "ra2UltraTransportSettings";
  const DEFAULT_SETTINGS = {
    videoQuality: "balanced",
    videoCodec: "H264",
    videoBitrate: "900000",
    audioEncoder: "opus",
    audioQuality: "44100",
    audioBitrate: "96000",
    inputMoveHz: "125",
  };
  const VIDEO_DECODER_CODECS = {
    H264: ["avc1.42E01F"],
    H265: ["hev1.1.6.L93.B0", "hvc1.1.6.L93.B0"],
  };

  const canvas = document.getElementById("canvas");
  const ctx = canvas.getContext("2d", { alpha: false });
  const overlay = document.getElementById("overlay");
  const overlayStatus = document.getElementById("overlayStatus");
  const controlPanel = document.getElementById("controlPanel");
  const panelHeader = document.getElementById("panelHeader");
  const panelToggle = document.getElementById("panelToggle");
  const transportStatus = document.getElementById("transportStatus");
  const pendingNotice = document.getElementById("pendingNotice");
  const videoQualityEl = document.getElementById("videoQuality");
  const videoCodecEl = document.getElementById("videoCodec");
  const videoBitrateEl = document.getElementById("videoBitrate");
  const audioEncoderEl = document.getElementById("audioEncoder");
  const audioBitrateEl = document.getElementById("audioBitrate");
  const audioQualityEl = document.getElementById("audioQuality");
  const audioTestEl = document.getElementById("audioTest");
  const inputMoveHzEl = document.getElementById("inputMoveHz");

  let ws = null;
  let videoDecoder = null;
  let audioDecoder = null;
  let audioContext = null;
  let audioNextTime = 0;
  let configured = false;
  let activeVideoCodec = "H264";
  let activeAudioEncoder = "opus";
  let activeAudioRate = 44100;
  let activeAudioBitrate = 96000;
  let framesDecoded = 0;
  let framesDropped = 0;
  let lastMoveAt = 0;
  let moveInterval = 1000 / 125;
  let reconnectTimer = null;
  let pingTimer = null;
  let rttMs = 0;
  let decodeQueue = 0;
  let videoMessages = 0;
  let audioMessages = 0;
  let audioPlayed = 0;
  let audioErrors = 0;
  let inputMessages = 0;
  let lastInput = "none";
  const pressedKeys = new Set();
  let streamWidth = canvas.width;
  let streamHeight = canvas.height;
  let connectionState = "idle";
  let pendingSettings = false;
  let activeTransport = null;
  let serverAvailable = null;
  let serverFallbacks = [];
  let browserFallbacks = [];
  let activeVideoDecoderCodec = VIDEO_DECODER_CODECS.H264[0];
  let audioOutputStatus = "not initialized";
  let audioPeak = 0;
  let lastAudioAt = 0;

  function loadSettings() {
    try {
      const raw = localStorage.getItem(SETTINGS_KEY);
      if (!raw) return { ...DEFAULT_SETTINGS };
      return { ...DEFAULT_SETTINGS, ...JSON.parse(raw) };
    } catch {
      return { ...DEFAULT_SETTINGS };
    }
  }

  function saveSettings(settings) {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings));
  }

  function currentSettingsFromUi() {
    return {
      videoQuality: videoQualityEl.value,
      videoCodec: videoCodecEl.value,
      videoBitrate: videoBitrateEl.value,
      audioEncoder: audioEncoderEl.value,
      audioBitrate: audioBitrateEl.value,
      audioQuality: audioQualityEl.value,
      inputMoveHz: inputMoveHzEl.value,
    };
  }

  function applySettingsToUi(settings) {
    videoQualityEl.value = settings.videoQuality;
    videoCodecEl.value = settings.videoCodec;
    videoBitrateEl.value = settings.videoBitrate;
    audioEncoderEl.value = settings.audioEncoder;
    audioBitrateEl.value = settings.audioBitrate;
    audioQualityEl.value = settings.audioQuality;
    inputMoveHzEl.value = settings.inputMoveHz;
    moveInterval = 1000 / Number(settings.inputMoveHz || 125);
  }

  function markPendingIfConnected() {
    if (ws && ws.readyState === WebSocket.OPEN) {
      pendingSettings = true;
      pendingNotice.classList.add("visible");
    } else {
      pendingSettings = false;
      pendingNotice.classList.remove("visible");
    }
    updateTransportStatus();
  }

  function updateAvailability(available) {
    if (!available) return;
    serverAvailable = available;
    const unavailableVideo = (available.unavailable && available.unavailable.videoCodec) || {};
    const unavailableAudio = (available.unavailable && available.unavailable.audioEncoder) || {};
    for (const option of videoCodecEl.options) {
      if (option.value === "H265") {
        option.disabled = !available.videoCodec.includes("H265");
        option.title = unavailableVideo.H265 || "";
      }
    }
    if (!available.videoCodec.includes(videoCodecEl.value)) {
      videoCodecEl.value = "H264";
      saveSettings(currentSettingsFromUi());
    }
    for (const option of videoBitrateEl.options) {
      option.disabled = available.videoBitrate && !available.videoBitrate.includes(Number(option.value));
    }
    for (const option of audioEncoderEl.options) {
      option.disabled = !available.audioEncoder.includes(option.value);
      option.title = unavailableAudio[option.value] || "";
    }
  }

  function updateTransportStatus(extraLines = []) {
    const settings = currentSettingsFromUi();
    const lines = [
      "RA2 Ultra transport",
      `connection: ${connectionState}`,
      `requested: ${settings.videoQuality}/${settings.videoCodec}@${settings.videoBitrate}bps ${settings.audioEncoder}@${settings.audioBitrate}bps/${settings.audioQuality}Hz input=${settings.inputMoveHz}Hz`,
    ];
    if (activeTransport) {
      lines.push(`active: ${activeTransport.video} ${activeTransport.audio} input=${activeTransport.input}`);
    }
    if (serverFallbacks.length) {
      for (const fb of serverFallbacks) {
        lines.push(`fallback: ${fb.field} ${fb.requested} -> ${fb.active} (${fb.reason})`);
      }
    }
    if (browserFallbacks.length) {
      for (const fb of browserFallbacks) {
        lines.push(`browser fallback: ${fb.field} ${fb.requested} -> ${fb.active} (${fb.reason})`);
      }
    }
    if (pendingSettings) {
      lines.push("pending: changes apply on reconnect");
    }
    lines.push(
      `decoder: ${activeVideoDecoderCodec}`,
      `video: ${streamWidth}x${streamHeight}`,
      `rx: v=${videoMessages} a=${audioMessages}`,
      `audio: state=${audioContext ? audioContext.state : "none"} played=${audioPlayed} err=${audioErrors}`,
      `audio output: ${audioOutputStatus}`,
      `audio meter: peak=${audioPeak.toFixed(3)} age=${lastAudioAt ? Math.round(performance.now() - lastAudioAt) + "ms" : "never"}`,
      `input: ${inputMessages} ${lastInput}`,
      `decoded: ${framesDecoded} dropped=${framesDropped}`,
      `queue: ${decodeQueue} rtt=${rttMs}ms`,
      ...extraLines
    );
    transportStatus.textContent = lines.join("\n");
  }

  function setStatus(text) {
    overlayStatus.textContent = text;
    overlay.classList.remove("hidden");
  }

  function hideOverlay() {
    overlay.classList.add("hidden");
  }

  function wsUrl() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    return `${proto}//${location.host}/stream`;
  }

  function b64ToU8(b64) {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i += 1) out[i] = bin.charCodeAt(i);
    return out;
  }

  function videoCodecString(codec) {
    const upper = String(codec || "H264").toUpperCase();
    if (upper === "H265" || upper === "HEVC") {
      return activeVideoDecoderCodec;
    }
    return "avc1.42E01F";
  }

  function noteAudioPeak(value) {
    audioPeak = Math.max(audioPeak * 0.9, Math.min(1, value));
    lastAudioAt = performance.now();
  }

  function ensureAudioContext() {
    if (!audioContext) {
      const AudioContextClass = window.AudioContext || window.webkitAudioContext;
      if (!AudioContextClass) {
        throw new Error("Web Audio API is not available in this browser");
      }
      audioContext = new AudioContextClass({ latencyHint: "interactive", sampleRate: 44100 });
      audioOutputStatus = `created (${audioContext.state})`;
    }
    return audioContext;
  }

  function unlockAudio() {
    const context = ensureAudioContext();
    if (context.state !== "running") {
      context.resume().then(() => {
        audioOutputStatus = `unlocked (${context.state})`;
        updateTransportStatus();
      }).catch((e) => {
        audioErrors += 1;
        audioOutputStatus = `unlock failed: ${e && e.message ? e.message : e}`;
        console.error("audio unlock", e);
        updateTransportStatus();
      });
    } else {
      audioOutputStatus = "already running";
    }
    return context;
  }

  function playTestTone() {
    const context = ensureAudioContext();
    const scheduleTone = () => {
      const osc = context.createOscillator();
      const gain = context.createGain();
      osc.frequency.value = 880;
      gain.gain.setValueAtTime(0.0001, context.currentTime);
      gain.gain.exponentialRampToValueAtTime(0.2, context.currentTime + 0.03);
      gain.gain.setValueAtTime(0.2, context.currentTime + 0.8);
      gain.gain.exponentialRampToValueAtTime(0.0001, context.currentTime + 1.0);
      osc.connect(gain);
      gain.connect(context.destination);
      osc.start();
      osc.stop(context.currentTime + 1.05);
      audioOutputStatus = `test tone sent (${context.state})`;
      noteAudioPeak(0.2);
      audioNextTime = Math.max(audioNextTime, context.currentTime + 1.1);
      updateTransportStatus();
    };
    if (context.state !== "running") {
      context.resume().then(scheduleTone).catch((e) => {
        audioErrors += 1;
        console.error("audio test", e);
        updateTransportStatus();
      });
    } else {
      scheduleTone();
    }
    playElementTone();
  }

  function wavToneUrl() {
    const sampleRate = 44100;
    const seconds = 1;
    const frames = sampleRate * seconds;
    const dataBytes = frames * 2;
    const wav = new ArrayBuffer(44 + dataBytes);
    const view = new DataView(wav);
    const writeAscii = (offset, value) => {
      for (let i = 0; i < value.length; i += 1) view.setUint8(offset + i, value.charCodeAt(i));
    };
    writeAscii(0, "RIFF");
    view.setUint32(4, 36 + dataBytes, true);
    writeAscii(8, "WAVE");
    writeAscii(12, "fmt ");
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 1, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * 2, true);
    view.setUint16(32, 2, true);
    view.setUint16(34, 16, true);
    writeAscii(36, "data");
    view.setUint32(40, dataBytes, true);
    for (let i = 0; i < frames; i += 1) {
      const envelope = i < 2000 ? i / 2000 : Math.max(0, (frames - i) / 6000);
      const sample = Math.sin((2 * Math.PI * 880 * i) / sampleRate) * 0.35 * Math.min(1, envelope);
      view.setInt16(44 + i * 2, Math.round(sample * 32767), true);
    }
    return URL.createObjectURL(new Blob([wav], { type: "audio/wav" }));
  }

  function playElementTone() {
    const audio = new Audio(wavToneUrl());
    audio.volume = 1;
    audio.onended = () => {
      URL.revokeObjectURL(audio.src);
    };
    audio.play().then(() => {
      audioOutputStatus = `test tone sent (${audioContext ? audioContext.state : "media element"})`;
      noteAudioPeak(0.35);
      updateTransportStatus();
    }).catch((e) => {
      audioErrors += 1;
      audioOutputStatus = `media test failed: ${e && e.message ? e.message : e}`;
      updateTransportStatus();
    });
  }

  async function supportsOpusAudioDecoder() {
    if (!("AudioDecoder" in window) || !("EncodedAudioChunk" in window)) {
      return false;
    }
    if (typeof AudioDecoder.isConfigSupported !== "function") {
      return false;
    }
    try {
      const result = await AudioDecoder.isConfigSupported({
        codec: "opus",
        sampleRate: 48000,
        numberOfChannels: 2,
      });
      return Boolean(result && result.supported);
    } catch {
      return false;
    }
  }

  async function supportedVideoDecoderCodec(codec) {
    if (!("VideoDecoder" in window) || typeof VideoDecoder.isConfigSupported !== "function") {
      return null;
    }
    const upper = String(codec || "H264").toUpperCase();
    const candidates = VIDEO_DECODER_CODECS[upper] || VIDEO_DECODER_CODECS.H264;
    for (const candidate of candidates) {
      try {
        const result = await VideoDecoder.isConfigSupported({
          codec: candidate,
          codedWidth: streamWidth,
          codedHeight: streamHeight,
          hardwareAcceleration: "prefer-hardware",
        });
        if (result && result.supported) {
          return candidate;
        }
      } catch {
        // Try the next browser-specific codec string.
      }
    }
    return null;
  }

  async function browserCompatibleSettings(settings) {
    browserFallbacks = [];
    const compatible = { ...settings };
    const requestedVideo = String(compatible.videoCodec || "H264").toUpperCase();
    const videoDecoderCodec = await supportedVideoDecoderCodec(requestedVideo);
    if (videoDecoderCodec) {
      activeVideoDecoderCodec = videoDecoderCodec;
    } else if (requestedVideo !== "H264") {
      const h264DecoderCodec = await supportedVideoDecoderCodec("H264");
      if (h264DecoderCodec) {
        compatible.videoCodec = "H264";
        activeVideoDecoderCodec = h264DecoderCodec;
        browserFallbacks.push({
          field: "videoCodec",
          requested: requestedVideo,
          active: "H264",
          reason: "HEVC VideoDecoder unsupported in this browser",
        });
      }
    }
    if (compatible.audioEncoder === "opus" && !(await supportsOpusAudioDecoder())) {
      compatible.audioEncoder = "pcm";
      browserFallbacks.push({
        field: "audioEncoder",
        requested: "opus",
        active: "pcm",
        reason: "Opus AudioDecoder unsupported in this browser",
      });
    }
    return compatible;
  }

  async function ensureDecoders() {
    if (!("VideoDecoder" in window)) {
      throw new Error("WebCodecs VideoDecoder required (use Chromium/Chrome/Edge)");
    }
    if (videoDecoder) return;
    videoDecoder = new VideoDecoder({
      output: (frame) => {
        decodeQueue = Math.max(0, decodeQueue - 1);
        framesDecoded += 1;
        if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
          canvas.width = frame.displayWidth;
          canvas.height = frame.displayHeight;
        }
        streamWidth = frame.displayWidth;
        streamHeight = frame.displayHeight;
        ctx.drawImage(frame, 0, 0);
        frame.close();
        updateTransportStatus();
      },
      error: (e) => {
        console.error("video decoder", e);
        framesDropped += 1;
      },
    });
    if (!audioContext) {
      ensureAudioContext();
    }
  }

  function resetVideoDecoder() {
    configured = false;
    if (videoDecoder && videoDecoder.state !== "closed") {
      try {
        videoDecoder.close();
      } catch {
        // ignore close races during reconnect
      }
    }
    videoDecoder = null;
  }

  function resetAudioDecoder() {
    if (audioDecoder && audioDecoder.state !== "closed") {
      try {
        audioDecoder.close();
      } catch {
        // ignore close races during reconnect
      }
    }
    audioDecoder = null;
  }

  function playAudioData(audioData) {
    if (!audioContext) {
      audioData.close();
      return;
    }
    try {
      const buffer = audioContext.createBuffer(
        audioData.numberOfChannels,
        audioData.numberOfFrames,
        audioData.sampleRate
      );
      for (let ch = 0; ch < audioData.numberOfChannels; ch += 1) {
        const copy = new Float32Array(audioData.numberOfFrames);
        audioData.copyTo(copy, { planeIndex: ch, format: "f32-planar" });
        if (ch === 0) {
          let peak = 0;
          for (let i = 0; i < copy.length; i += 1) peak = Math.max(peak, Math.abs(copy[i]));
          noteAudioPeak(peak);
        }
        buffer.copyToChannel(copy, ch);
      }
      scheduleAudioBuffer(buffer);
      audioPlayed += 1;
    } catch (e) {
      audioErrors += 1;
      console.error("audio decoder output", e);
    } finally {
      audioData.close();
    }
    updateTransportStatus();
  }

  function ensureAudioDecoder() {
    if (activeAudioEncoder !== "opus") return;
    if (!("AudioDecoder" in window)) {
      throw new Error("WebCodecs AudioDecoder required for Opus audio");
    }
    if (audioDecoder && audioDecoder.state !== "closed") return;
    audioDecoder = new AudioDecoder({
      output: playAudioData,
      error: (e) => {
        audioErrors += 1;
        console.error("audio decoder", e);
        updateTransportStatus();
      },
    });
    audioDecoder.configure({
      codec: "opus",
      sampleRate: activeAudioRate,
      numberOfChannels: 2,
    });
  }

  function scheduleAudioBuffer(buffer) {
    const src = audioContext.createBufferSource();
    src.buffer = buffer;
    src.connect(audioContext.destination);
    const now = audioContext.currentTime;
    if (audioNextTime < now + 0.02) audioNextTime = now + 0.02;
    src.start(audioNextTime);
    audioNextTime += buffer.duration;
  }

  function decodeVideo(msg) {
    videoMessages += 1;
    const data = b64ToU8(msg.data);
    if (!configured && msg.key) {
      try {
        videoDecoder.configure({
          codec: videoCodecString(activeVideoCodec),
          codedWidth: streamWidth,
          codedHeight: streamHeight,
          hardwareAcceleration: "prefer-hardware",
          optimizeForLatency: true,
        });
        configured = true;
        connectionState = "decoding";
      } catch (e) {
        framesDropped += 1;
        browserFallbacks.push({
          field: "videoCodec",
          requested: activeVideoCodec,
          active: "none",
          reason: `VideoDecoder configure failed: ${e.message || e}`,
        });
        console.error("video decoder configure", activeVideoCodec, e);
        updateTransportStatus();
        return;
      }
    }
    if (!configured) return;
    decodeQueue += 1;
    try {
      videoDecoder.decode(
        new EncodedVideoChunk({
          type: msg.key ? "key" : "delta",
          timestamp: msg.ts * 1000,
          data,
        })
      );
    } catch (e) {
      framesDropped += 1;
      console.error("video decoder decode", activeVideoCodec, e);
      updateTransportStatus([`video decode error: ${e.message || e}`]);
    }
  }

  function decodeAudio(msg) {
    audioMessages += 1;
    if (!audioContext) return;
    if (activeAudioEncoder === "opus") {
      try {
        const packetRate = Number(msg.rate || activeAudioRate);
        if (packetRate !== activeAudioRate) {
          activeAudioRate = packetRate;
          resetAudioDecoder();
        }
        ensureAudioDecoder();
        audioDecoder.decode(
          new EncodedAudioChunk({
            type: "key",
            timestamp: msg.ts * 1000,
            data: b64ToU8(msg.data),
          })
        );
      } catch (e) {
        audioErrors += 1;
        console.error("opus audio playback", e);
      }
      updateTransportStatus();
      return;
    }
    try {
      const data = b64ToU8(msg.data);
      const samples = data.length / 4;
      const buffer = audioContext.createBuffer(2, samples, activeAudioRate);
      const left = buffer.getChannelData(0);
      const right = buffer.getChannelData(1);
      for (let i = 0, frame = 0; i + 3 < data.length; i += 4, frame += 1) {
        let l = data[i] | (data[i + 1] << 8);
        let r = data[i + 2] | (data[i + 3] << 8);
        if (l & 0x8000) l -= 0x10000;
        if (r & 0x8000) r -= 0x10000;
        left[frame] = l / 32768;
        right[frame] = r / 32768;
        if ((frame & 63) === 0) {
          noteAudioPeak(Math.max(Math.abs(left[frame]), Math.abs(right[frame])));
        }
      }
      scheduleAudioBuffer(buffer);
      audioPlayed += 1;
    } catch (e) {
      audioErrors += 1;
      console.error("audio playback", e);
    }
    updateTransportStatus();
  }

  function sendInput(event) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    inputMessages += 1;
    lastInput = event.type;
    updateTransportStatus();
    ws.send(JSON.stringify(event));
  }

  function releasePressedKeys() {
    if (!pressedKeys.size) return;
    for (const key of pressedKeys) {
      sendInput({ type: "keyup", key });
    }
    pressedKeys.clear();
    sendInput({ type: "keyup_all" });
  }

  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  function canvasContentRect() {
    const rect = canvas.getBoundingClientRect();
    const sourceWidth = streamWidth || canvas.width || 1024;
    const sourceHeight = streamHeight || canvas.height || 768;
    const sourceAspect = sourceWidth / sourceHeight;
    const rectAspect = rect.width / rect.height;
    let width = rect.width;
    let height = rect.height;
    let left = rect.left;
    let top = rect.top;

    if (rectAspect > sourceAspect) {
      width = rect.height * sourceAspect;
      left = rect.left + (rect.width - width) / 2;
    } else if (rectAspect < sourceAspect) {
      height = rect.width / sourceAspect;
      top = rect.top + (rect.height - height) / 2;
    }

    return { left, top, width, height };
  }

  function mapMouse(e) {
    const rect = canvasContentRect();
    const x = Math.round(clamp((e.clientX - rect.left) / rect.width, 0, 1) * (canvas.width - 1));
    const y = Math.round(clamp((e.clientY - rect.top) / rect.height, 0, 1) * (canvas.height - 1));
    return { x, y };
  }

  function bindInput() {
    canvas.tabIndex = 0;
    canvas.addEventListener("contextmenu", (e) => e.preventDefault());

    const moveEvent = window.PointerEvent ? "pointermove" : "mousemove";
    const downEvent = window.PointerEvent ? "pointerdown" : "mousedown";
    const upEvent = window.PointerEvent ? "pointerup" : "mouseup";

    canvas.addEventListener(moveEvent, (e) => {
      const now = performance.now();
      if (now - lastMoveAt < moveInterval) return;
      lastMoveAt = now;
      const { x, y } = mapMouse(e);
      sendInput({ type: "mousemove", x, y });
    });
    canvas.addEventListener(downEvent, (e) => {
      canvas.focus({ preventScroll: true });
      if (e.pointerId !== undefined && canvas.setPointerCapture) {
        try {
          canvas.setPointerCapture(e.pointerId);
        } catch {
          // Pointer capture can fail if the pointer is already released.
        }
      }
      const { x, y } = mapMouse(e);
      sendInput({ type: "mousedown", x, y, button: e.button + 1 });
      e.preventDefault();
    });
    canvas.addEventListener(upEvent, (e) => {
      const { x, y } = mapMouse(e);
      sendInput({ type: "mouseup", x, y, button: e.button + 1 });
      e.preventDefault();
    });
    canvas.addEventListener("wheel", (e) => {
      sendInput({ type: "wheel", deltaY: e.deltaY });
      e.preventDefault();
    }, { passive: false });
    window.addEventListener("keydown", (e) => {
      if (e.repeat) return;
      if (pressedKeys.has(e.key)) {
        e.preventDefault();
        return;
      }
      pressedKeys.add(e.key);
      sendInput({ type: "keydown", key: e.key });
      e.preventDefault();
    });
    window.addEventListener("keyup", (e) => {
      pressedKeys.delete(e.key);
      sendInput({ type: "keyup", key: e.key });
      e.preventDefault();
    });
    window.addEventListener("blur", releasePressedKeys);
    window.addEventListener("pagehide", releasePressedKeys);
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) releasePressedKeys();
    });
  }

  function bindSettingsUi() {
    panelHeader.addEventListener("click", () => {
      controlPanel.classList.toggle("collapsed");
      panelToggle.textContent = controlPanel.classList.contains("collapsed") ? "▼" : "▲";
    });
    audioTestEl.addEventListener("click", (e) => {
      e.stopPropagation();
      playTestTone();
    });
    for (const el of [videoQualityEl, videoCodecEl, videoBitrateEl, audioEncoderEl, audioBitrateEl, audioQualityEl, inputMoveHzEl]) {
      el.addEventListener("change", () => {
        const settings = currentSettingsFromUi();
        saveSettings(settings);
        moveInterval = 1000 / Number(settings.inputMoveHz || 125);
        markPendingIfConnected();
      });
    }
  }

  function scheduleReconnect() {
    if (reconnectTimer) return;
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connect();
    }, 2000);
  }

  async function connect() {
    connectionState = "connecting";
    unlockAudio();
    pendingSettings = false;
    pendingNotice.classList.remove("visible");
    updateTransportStatus();
    setStatus("Connecting…");
    await ensureDecoders();
    if (ws) {
      releasePressedKeys();
      ws.close();
      ws = null;
    }
    resetVideoDecoder();
    resetAudioDecoder();
    await ensureDecoders();
    const settings = loadSettings();
    applySettingsToUi(settings);
    saveSettings(settings);
    const startSettings = await browserCompatibleSettings(settings);
    updateTransportStatus();
    ws = new WebSocket(wsUrl());
    ws.onopen = () => {
      connectionState = "connected";
      updateTransportStatus();
      hideOverlay();
      ws.send(JSON.stringify({ type: "start", settings: startSettings }));
      if (pingTimer) clearInterval(pingTimer);
      pingTimer = setInterval(() => {
        const t0 = performance.now();
        ws.send(JSON.stringify({ type: "ping", t: t0 }));
      }, 5000);
    };
    ws.onmessage = (ev) => {
      let msg;
      try {
        msg = JSON.parse(ev.data);
      } catch {
        return;
      }
      if (msg.type === "pong" && msg.clientT) {
        rttMs = Math.round(performance.now() - msg.clientT);
        updateTransportStatus();
        return;
      }
      if (msg.type === "hello") {
        if (msg.defaults) {
          applySettingsToUi({ ...DEFAULT_SETTINGS, ...loadSettings() });
        }
        updateAvailability(msg.available);
        updateTransportStatus();
        return;
      }
      if (msg.type === "ready") {
        connectionState = "stream starting";
        pendingSettings = false;
        pendingNotice.classList.remove("visible");
        if (msg.width && msg.height) {
          streamWidth = msg.width;
          streamHeight = msg.height;
        }
        if (msg.active) {
          activeVideoCodec = msg.active.videoCodec || "H264";
          activeAudioEncoder = msg.active.audioEncoder || "opus";
          activeAudioRate = Number(msg.active.audioTransportRate || msg.active.audioQuality || 48000);
          activeAudioBitrate = Number(msg.active.audioBitrate || 96000);
          moveInterval = 1000 / Number(msg.active.inputMoveHz || 125);
          resetAudioDecoder();
          if (activeAudioEncoder === "opus") ensureAudioDecoder();
        }
        activeTransport = msg.transport || null;
        serverFallbacks = msg.fallbacks || [];
        updateAvailability(msg.available);
        updateTransportStatus();
        return;
      }
      if (msg.type === "video") decodeVideo(msg);
      if (msg.type === "audio") decodeAudio(msg);
    };
    ws.onclose = () => {
      connectionState = "reconnecting";
      configured = false;
      setStatus("Disconnected — reconnecting…");
      scheduleReconnect();
    };
    ws.onerror = () => setStatus("Connection error");
  }

  overlay.addEventListener("click", () => {
    unlockAudio();
    connect();
  });
  bindInput();
  bindSettingsUi();
  applySettingsToUi(loadSettings());
  updateTransportStatus();
  setInterval(updateTransportStatus, 1000);
})();
