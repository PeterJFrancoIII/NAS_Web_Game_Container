(() => {
  "use strict";

  const SETTINGS_KEY = "ra2UltraTransportSettings";
  const SETTINGS_VERSION = 32;
  const OPUS_NATIVE_RATE = 48000;
  const AUDIO_START_LEAD_S = 0.05;
  const DEFAULT_SETTINGS = {
    settingsVersion: SETTINGS_VERSION,
    videoQuality: "balanced",
    videoCodec: "H265_10",
    videoBitrate: "2000000",
    audioEncoder: "opus",
    audioQuality: "48000",
    audioBitrate: "64000",
    inputMoveHz: "60",
  };
  const VIDEO_DECODER_CODECS = {
    H264: ["avc1.42E01F"],
    H265: ["hev1.1.6.L93.B0", "hvc1.1.6.L93.B0"],
    // Main10 profile (profile_idc=2, compatibility=4) for 10-bit HEVC.
    H265_10: ["hev1.2.4.L93.B0", "hvc1.2.4.L93.B0"],
  };

  const canvas = document.getElementById("canvas");
  const gameSurface = document.getElementById("gameSurface");
  const cursorOverlay = document.getElementById("cursorOverlay");
  const localCursor = document.getElementById("localCursor");
  const remoteCursor = document.getElementById("remoteCursor");
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
  const inputMoveHzEl = document.getElementById("inputMoveHz");
  const gameModeButton = document.getElementById("gameModeButton");
  const GAME_MODE_SHORTCUT = "Ctrl+Alt+L";

  let ws = null;
  let videoDecoder = null;
  let audioDecoder = null;
  let audioContext = null;
  let audioNextTime = 0;
  let configured = false;
  let activeVideoCodec = "H264";
  let activeAudioEncoder = "opus";
  let activeAudioRate = OPUS_NATIVE_RATE;
  let activeDecoderRate = 0;
  let audioStreamClock = null;
  const audioTimestampQueue = [];
  let activeAudioBitrate = 64000;
  let audioContextRate = 0;
  let framesDecoded = 0;
  let framesDropped = 0;
  let streamFps = 24;
  let frameIntervalMs = 1000 / 24;
  let pendingVideoFrame = null;
  let presentHandle = null;
  let nextPresentAt = 0;
  let lastMoveAt = 0;
  let moveInterval = 1000 / 60;
  let reconnectTimer = null;
  let pingTimer = null;
  let rttMs = 0;
  let decodeQueue = 0;
  let videoMessages = 0;
  let videoBytes = 0;
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
  let applyingTransport = false;
  let appliedSettings = null;
  let applyTransportTimer = null;
  let activeTransport = null;
  const TRANSPORT_APPLY_FIELDS = [
    "videoQuality",
    "videoCodec",
    "videoBitrate",
    "audioEncoder",
    "audioBitrate",
    "audioQuality",
    "inputMoveHz",
  ];
  let serverAvailable = null;
  let serverFallbacks = [];
  let browserFallbacks = [];
  let nativeWidth = canvas.width;
  let nativeHeight = canvas.height;
  let activeVideoDecoderCodec = VIDEO_DECODER_CODECS.H264[0];
  let audioOutputStatus = "not initialized";
  let audioPeak = 0;
  let lastAudioAt = 0;
  let streamStatsStartedAt = performance.now();
  let lastVideoFrameAt = 0;
  let lastVideoMessageAt = 0;
  let streamStalls = 0;
  let virtualMouseX = 0;
  let virtualMouseY = 0;
  let remoteSentGameX = 0;
  let remoteSentGameY = 0;
  let gameModeIntent = false;
  let gameModeBusy = false;
  let gameModeGraceUntil = 0;
  let lastGameModeToggleAt = 0;
  const STREAM_STALL_MS = 8000;
  const activeAudioSources = new Set();

  function loadSettings() {
    try {
      const raw = localStorage.getItem(SETTINGS_KEY);
      if (!raw) return { ...DEFAULT_SETTINGS };
      const saved = JSON.parse(raw);
      if (saved.settingsVersion !== SETTINGS_VERSION) {
        return { ...DEFAULT_SETTINGS };
      }
      return { ...DEFAULT_SETTINGS, ...saved, settingsVersion: SETTINGS_VERSION };
    } catch {
      return { ...DEFAULT_SETTINGS };
    }
  }

  function saveSettings(settings) {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings));
  }

  function parseDisplayResolution(value) {
    const match = String(value || "").match(/^(\d+)x(\d+)$/i);
    if (!match) {
      return { width: streamWidth || 1440, height: streamHeight || 1080 };
    }
    return { width: Number(match[1]), height: Number(match[2]) };
  }

  function currentSettingsFromUi() {
    return {
      settingsVersion: SETTINGS_VERSION,
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
    moveInterval = 1000 / Number(settings.inputMoveHz || 60);
  }

  function transportSettingsSnapshot(settings) {
    const snapshot = {};
    for (const field of TRANSPORT_APPLY_FIELDS) {
      snapshot[field] = settings[field];
    }
    return snapshot;
  }

  function transportSettingsChanged(previous, next) {
    return TRANSPORT_APPLY_FIELDS.some((field) => previous[field] !== next[field]);
  }

  function syncUiFromActive(active) {
    if (!active) return;
    if (active.videoFps) setStreamFps(active.videoFps);
    applyActiveAudioFromServer(active);
    applySettingsToUi({
      ...loadSettings(),
      videoQuality: active.videoQuality,
      videoCodec: active.videoCodec,
      videoBitrate: String(active.videoBitrate),
      audioEncoder: active.audioEncoder,
      audioBitrate: String(active.audioBitrate),
      audioQuality: String(active.audioQuality),
      inputMoveHz: String(active.inputMoveHz),
    });
    saveSettings(currentSettingsFromUi());
  }

  function scheduleTransportApply() {
    if (!ws || ws.readyState !== WebSocket.OPEN || !appliedSettings) return;
    if (applyTransportTimer) clearTimeout(applyTransportTimer);
    applyTransportTimer = setTimeout(() => {
      applyTransportTimer = null;
      void applyTransportSettings();
    }, 400);
  }

  async function applyTransportSettings() {
    if (!ws || ws.readyState !== WebSocket.OPEN || applyingTransport || !appliedSettings) return;
    const settings = await browserCompatibleSettings(currentSettingsFromUi());
    const next = transportSettingsSnapshot(settings);
    if (!transportSettingsChanged(appliedSettings, next)) return;

    applyingTransport = true;
    pendingSettings = false;
    pendingNotice.textContent = "Applying settings…";
    pendingNotice.classList.add("visible");
    connectionState = "streaming";
    updateTransportStatus();

    resetVideoDecoder();
    resetAudioPlayback();
    await ensureDecoders();

    ws.send(JSON.stringify({
      type: "reconfigure",
      settings,
    }));
  }

  function updateAvailability(available) {
    if (!available) return;
    serverAvailable = available;
    const unavailableVideo = (available.unavailable && available.unavailable.videoCodec) || {};
    const unavailableAudio = (available.unavailable && available.unavailable.audioEncoder) || {};
    for (const option of videoCodecEl.options) {
      const codecAvailable = available.videoCodec.includes(option.value);
      option.disabled = !codecAvailable;
      option.title = codecAvailable ? "" : unavailableVideo[option.value] || "";
    }
    if (!available.videoCodec.includes(videoCodecEl.value)) {
      const preferred = ["H265_10", "H265", "H264"].find((codec) =>
        available.videoCodec.includes(codec)
      );
      videoCodecEl.value = preferred || available.videoCodec[0] || "H264";
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
    const statsSeconds = Math.max((performance.now() - streamStatsStartedAt) / 1000, 0.001);
    const encodedVideoKbps = (videoBytes * 8) / statsSeconds / 1000;
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
    if (applyingTransport) {
      lines.push("applying: updating stream");
    } else if (pendingSettings) {
      lines.push("pending: waiting for stream");
    }
    lines.push(`native display: ${nativeWidth}x${nativeHeight}`);
    lines.push(
      `audio: ${activeAudioRate}Hz ${activeAudioEncoder}`,
      `decoder: ${activeVideoDecoderCodec}`,
      `video: ${streamWidth}x${streamHeight}`,
      `encoded video: ${encodedVideoKbps.toFixed(0)} kbps`,
      `rx: v=${videoMessages} a=${audioMessages}`,
      `audio: state=${audioContext ? audioContext.state : "none"} played=${audioPlayed} err=${audioErrors}`,
      `audio output: ${audioOutputStatus}`,
      `audio meter: peak=${audioPeak.toFixed(3)} age=${lastAudioAt ? Math.round(performance.now() - lastAudioAt) + "ms" : "never"}`,
      `input: ${inputMessages} ${lastInput}`,
      `decoded: ${framesDecoded} dropped=${framesDropped} stalls=${streamStalls}`,
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
    if (upper === "H265" || upper === "HEVC" || upper === "H265_10") {
      return activeVideoDecoderCodec;
    }
    return "avc1.42E01F";
  }

  function noteAudioPeak(value) {
    audioPeak = Math.max(audioPeak * 0.9, Math.min(1, value));
    lastAudioAt = performance.now();
  }

  function applyActiveAudioFromServer(active) {
    if (!active) return false;
    const encoder = String(active.audioEncoder || "opus").toLowerCase();
    const rate = Number(active.audioQuality || active.audioTransportRate || OPUS_NATIVE_RATE);
    const changed = encoder !== activeAudioEncoder || rate !== activeAudioRate;
    activeAudioEncoder = encoder;
    activeAudioRate = rate;
    activeAudioBitrate = Number(active.audioBitrate || activeAudioBitrate);
    if (changed) {
      resetAudioPlayback();
      if (audioContext) {
        audioContext.close();
        audioContext = null;
        audioContextRate = 0;
      }
      if (activeAudioEncoder === "opus") ensureAudioDecoder();
    }
    return changed;
  }

  function resetAudioClock() {
    audioStreamClock = null;
    audioTimestampQueue.length = 0;
  }

  function stopScheduledAudioSources() {
    for (const src of activeAudioSources) {
      try {
        src.stop();
      } catch {
        // Source may already have ended.
      }
    }
    activeAudioSources.clear();
    audioNextTime = audioContext ? audioContext.currentTime + 0.02 : 0;
  }

  function playbackSampleRate() {
    return activeDecoderRate || activeAudioRate || OPUS_NATIVE_RATE;
  }

  function ensureAudioContext() {
    if (!audioContext) {
      const AudioContextClass = window.AudioContext || window.webkitAudioContext;
      if (!AudioContextClass) {
        throw new Error("Web Audio API is not available in this browser");
      }
      // Use the device-native rate; Web Audio resamples decoded Opus buffers automatically.
      audioContext = new AudioContextClass({
        latencyHint: "interactive",
      });
      audioContextRate = audioContext.sampleRate;
      audioNextTime = audioContext.currentTime + 0.02;
      audioOutputStatus = `created (${audioContext.state} @ ${audioContextRate}Hz)`;
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

  async function supportsOpusAudioDecoder(sampleRate) {
    if (!("AudioDecoder" in window) || !("EncodedAudioChunk" in window)) {
      return false;
    }
    if (typeof AudioDecoder.isConfigSupported !== "function") {
      return false;
    }
    const rate = Number(sampleRate || activeAudioRate || OPUS_NATIVE_RATE);
    try {
      const result = await AudioDecoder.isConfigSupported({
        codec: "opus",
        sampleRate: rate,
        numberOfChannels: 2,
      });
      return Boolean(result && result.supported);
    } catch {
      return false;
    }
  }

  async function supportedVideoDecoderCodec(codec, resolutionValue) {
    if (!("VideoDecoder" in window) || typeof VideoDecoder.isConfigSupported !== "function") {
      return null;
    }
    const upper = String(codec || "H264").toUpperCase();
    const candidates = VIDEO_DECODER_CODECS[upper] || VIDEO_DECODER_CODECS.H264;
    const { width: codedWidth, height: codedHeight } = parseDisplayResolution(
      resolutionValue || `${streamWidth}x${streamHeight}`
    );
    for (const candidate of candidates) {
      try {
        const result = await VideoDecoder.isConfigSupported({
          codec: candidate,
          codedWidth,
          codedHeight,
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

  async function resolveOpusAudioQuality() {
    if (await supportsOpusAudioDecoder(OPUS_NATIVE_RATE)) {
      return String(OPUS_NATIVE_RATE);
    }
    return null;
  }

  async function browserCompatibleSettings(settings) {
    browserFallbacks = [];
    const compatible = { ...settings };
    const requestedVideo = String(compatible.videoCodec || "H264").toUpperCase();
    const videoDecoderCodec = await supportedVideoDecoderCodec(
      requestedVideo,
      `${streamWidth}x${streamHeight}`
    );
    if (videoDecoderCodec) {
      activeVideoDecoderCodec = videoDecoderCodec;
    } else if (requestedVideo !== "H264") {
      // 10-bit HEVC degrades to 8-bit HEVC before giving up and using H.264.
      const fallbackOrder = requestedVideo === "H265_10" ? ["H265", "H264"] : ["H264"];
      for (const fallback of fallbackOrder) {
        const fallbackDecoderCodec = await supportedVideoDecoderCodec(
          fallback,
          `${streamWidth}x${streamHeight}`
        );
        if (!fallbackDecoderCodec) continue;
        compatible.videoCodec = fallback;
        activeVideoDecoderCodec = fallbackDecoderCodec;
        browserFallbacks.push({
          field: "videoCodec",
          requested: requestedVideo,
          active: fallback,
          reason:
            requestedVideo === "H265_10" && fallback === "H265"
              ? "10-bit HEVC VideoDecoder unsupported in this browser"
              : "HEVC VideoDecoder unsupported in this browser",
        });
        break;
      }
    }
    if (compatible.audioEncoder === "opus") {
      const resolvedRate = await resolveOpusAudioQuality();
      if (!resolvedRate) {
        compatible.audioEncoder = "pcm";
        browserFallbacks.push({
          field: "audioEncoder",
          requested: "opus",
          active: "pcm",
          reason: "Opus AudioDecoder unsupported in this browser",
        });
      } else if (resolvedRate !== compatible.audioQuality) {
        browserFallbacks.push({
          field: "audioQuality",
          requested: compatible.audioQuality,
          active: resolvedRate,
          reason: "Opus requires 48 kHz for aligned native and transport audio",
        });
        compatible.audioQuality = resolvedRate;
      }
    }
    return compatible;
  }

  function setStreamFps(fps) {
    streamFps = Math.max(1, Number(fps) || 24);
    frameIntervalMs = 1000 / streamFps;
    nextPresentAt = 0;
  }

  function scheduleVideoPresent() {
    if (presentHandle !== null || !pendingVideoFrame) return;
    if (typeof canvas.requestVideoFrameCallback === "function") {
      presentHandle = canvas.requestVideoFrameCallback(onPresentFrame);
      return;
    }
    presentHandle = requestAnimationFrame(onPresentFrame);
  }

  function onPresentFrame(now) {
    presentHandle = null;
    if (!pendingVideoFrame) return;
    const ts = typeof now === "number" ? now : performance.now();
    if (nextPresentAt > 0 && ts < nextPresentAt) {
      scheduleVideoPresent();
      return;
    }
    const frame = pendingVideoFrame;
    pendingVideoFrame = null;
    const fw = frame.displayWidth;
    const fh = frame.displayHeight;
    if (fw !== streamWidth || fh !== streamHeight) {
      syncStreamDimensions(fw, fh);
    }
    ctx.drawImage(frame, 0, 0);
    frame.close();
    framesDecoded += 1;
    lastVideoFrameAt = performance.now();
    nextPresentAt = ts + frameIntervalMs;
    updateTransportStatus();
    if (pendingVideoFrame) scheduleVideoPresent();
  }

  function resetVideoPresenter() {
    if (presentHandle !== null && typeof canvas.cancelVideoFrameCallback === "function") {
      try {
        canvas.cancelVideoFrameCallback(presentHandle);
      } catch {
        // ignore cancel races
      }
    } else if (presentHandle !== null) {
      cancelAnimationFrame(presentHandle);
    }
    presentHandle = null;
    if (pendingVideoFrame) {
      pendingVideoFrame.close();
      pendingVideoFrame = null;
    }
    nextPresentAt = 0;
  }

  async function ensureDecoders() {
    if (!("VideoDecoder" in window)) {
      throw new Error("WebCodecs VideoDecoder required (use Chromium/Chrome/Edge)");
    }
    if (videoDecoder) return;
    videoDecoder = new VideoDecoder({
      output: (frame) => {
        decodeQueue = Math.max(0, decodeQueue - 1);
        if (pendingVideoFrame) {
          pendingVideoFrame.close();
          framesDropped += 1;
        }
        pendingVideoFrame = frame;
        scheduleVideoPresent();
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
    resetVideoPresenter();
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

  function resetAudioPlayback() {
    resetAudioDecoder();
    resetAudioClock();
    stopScheduledAudioSources();
    activeDecoderRate = 0;
  }

  function playAudioData(audioData) {
    if (!audioContext) {
      audioData.close();
      return;
    }
    try {
      activeDecoderRate = audioData.sampleRate;
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
    if (audioDecoder && audioDecoder.state !== "closed") {
      return;
    }
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

  function startAudioBufferAt(buffer, startAt) {
    const src = audioContext.createBufferSource();
    src.buffer = buffer;
    src.connect(audioContext.destination);
    activeAudioSources.add(src);
    src.onended = () => {
      activeAudioSources.delete(src);
      try {
        src.disconnect();
      } catch {
        // ignore disconnect races
      }
    };
    src.start(startAt);
  }

  function scheduleAudioBuffer(buffer) {
    if (!audioContext) return;
    const now = audioContext.currentTime;
    if (audioNextTime < now + 0.02) {
      audioNextTime = now + AUDIO_START_LEAD_S;
    }
    startAudioBufferAt(buffer, audioNextTime);
    audioNextTime += buffer.duration;
  }

  function decodeVideo(msg) {
    videoMessages += 1;
    lastVideoMessageAt = performance.now();
    const data = b64ToU8(msg.data);
    videoBytes += data.length;
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
    unlockAudio();
    if (!audioContext) return;
    const packetCodec = String(msg.codec || activeAudioEncoder).toLowerCase();
    const packetRate = Number(msg.rate || msg.sourceRate || activeAudioRate);
    const negotiatedRate =
      activeAudioEncoder === "opus" ? OPUS_NATIVE_RATE : packetRate;
    if (
      packetCodec !== activeAudioEncoder ||
      (activeAudioEncoder === "opus" && packetRate !== OPUS_NATIVE_RATE) ||
      (activeAudioEncoder !== "opus" && packetRate !== activeAudioRate)
    ) {
      applyActiveAudioFromServer({
        audioEncoder: packetCodec,
        audioQuality: negotiatedRate,
        audioTransportRate: negotiatedRate,
        audioBitrate: activeAudioBitrate,
      });
    }
    if (activeAudioEncoder === "opus") {
      try {
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
      const playbackRate = packetRate || activeAudioRate;
      const buffer = audioContext.createBuffer(2, samples, playbackRate);
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
    if (
      (event.type === "mousemove" || event.type === "mousedown" || event.type === "mouseup")
      && typeof event.x === "number"
      && typeof event.y === "number"
    ) {
      remoteSentGameX = event.x;
      remoteSentGameY = event.y;
      updateCursorOverlay();
    }
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

  function syncStreamDimensions(width, height) {
    const w = Math.round(Number(width));
    const h = Math.round(Number(height));
    if (!(w > 0 && h > 0)) return;
    streamWidth = w;
    streamHeight = h;
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
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

  function activeFullscreenElement() {
    return document.fullscreenElement || document.webkitFullscreenElement || null;
  }

  function isGameModeFullscreen() {
    const fs = activeFullscreenElement();
    return fs === gameSurface || fs === canvas;
  }

  function isPointerLocked() {
    return document.pointerLockElement === gameSurface
      || document.pointerLockElement === canvas;
  }

  function isGameModeActive() {
    return gameModeIntent || isPointerLocked() || isGameModeFullscreen();
  }

  async function exitGameModeInternal() {
    if (document.pointerLockElement) {
      document.exitPointerLock();
    }
    if (activeFullscreenElement()) {
      try {
        if (document.exitFullscreen) {
          await document.exitFullscreen();
        } else if (document.webkitExitFullscreen) {
          document.webkitExitFullscreen();
        }
      } catch {
        // Fullscreen may already be exiting when Esc is pressed.
      }
    }
  }

  function requestGameModeFullscreen() {
    if (isGameModeFullscreen()) {
      return null;
    }
    if (gameSurface.requestFullscreen) {
      return gameSurface.requestFullscreen({ navigationUI: "hide" });
    }
    if (gameSurface.webkitRequestFullscreen) {
      gameSurface.webkitRequestFullscreen();
      return null;
    }
    throw new Error("Fullscreen not supported");
  }

  function requestGameModePointerLock() {
    if (gameSurface.requestPointerLock) {
      return gameSurface.requestPointerLock();
    }
    if (gameSurface.webkitRequestPointerLock) {
      gameSurface.webkitRequestPointerLock();
      return null;
    }
    throw new Error("Pointer lock not supported");
  }

  function noteGameModeError(label, error) {
    const message = error && error.message ? error.message : String(error);
    updateTransportStatus([`game mode ${label}: ${message}`]);
  }

  function gameCoordsFromClient(clientX, clientY) {
    const rect = canvasContentRect();
    const w = streamWidth || canvas.width;
    const h = streamHeight || canvas.height;
    const x = Math.round(clamp((clientX - rect.left) / rect.width, 0, 1) * (w - 1));
    const y = Math.round(clamp((clientY - rect.top) / rect.height, 0, 1) * (h - 1));
    return { x, y };
  }

  function syncVirtualMouseFromClient(clientX, clientY) {
    const rect = canvasContentRect();
    virtualMouseX = clamp(clientX, rect.left, rect.left + rect.width - 0.001);
    virtualMouseY = clamp(clientY, rect.top, rect.top + rect.height - 0.001);
  }

  function centerVirtualMouse() {
    const rect = canvasContentRect();
    virtualMouseX = rect.left + rect.width / 2;
    virtualMouseY = rect.top + rect.height / 2;
  }

  function applyPointerDelta(event) {
    const rect = canvasContentRect();
    virtualMouseX = clamp(virtualMouseX + event.movementX, rect.left, rect.left + rect.width - 0.001);
    virtualMouseY = clamp(virtualMouseY + event.movementY, rect.top, rect.top + rect.height - 0.001);
  }

  function gameCoordsToScreen(gameX, gameY) {
    const rect = canvasContentRect();
    const w = Math.max(1, (streamWidth || canvas.width) - 1);
    const h = Math.max(1, (streamHeight || canvas.height) - 1);
    return {
      clientX: rect.left + (gameX / w) * rect.width,
      clientY: rect.top + (gameY / h) * rect.height,
    };
  }

  function placeCursorMarker(marker, clientX, clientY) {
    if (!marker) return;
    marker.style.left = `${clientX}px`;
    marker.style.top = `${clientY}px`;
  }

  function updateCursorOverlay() {
    if (!cursorOverlay) return;
    if (!isPointerLocked()) {
      cursorOverlay.classList.add("hidden");
      return;
    }

    const localX = virtualMouseX;
    const localY = virtualMouseY;
    const remote = gameCoordsToScreen(remoteSentGameX, remoteSentGameY);

    placeCursorMarker(localCursor, localX, localY);
    placeCursorMarker(remoteCursor, remote.clientX, remote.clientY);
    cursorOverlay.classList.remove("hidden");
  }

  function mapMouse(e) {
    if (isPointerLocked()) {
      return gameCoordsFromClient(virtualMouseX, virtualMouseY);
    }
    return gameCoordsFromClient(e.clientX, e.clientY);
  }

  function updateGameModeUi() {
    const locked = isPointerLocked();
    const fullscreen = isGameModeFullscreen();
    document.documentElement.classList.toggle("game-mode-locked", locked);
    document.documentElement.classList.toggle("game-mode-fullscreen", fullscreen);
    if (gameModeButton) {
      gameModeButton.textContent = isGameModeActive()
        ? "Exit game mode"
        : "Game mode (fullscreen + lock)";
    }
    updateCursorOverlay();
  }

  function enterGameMode() {
    if (gameModeBusy || gameModeIntent) return;
    releasePressedKeys();
    gameModeBusy = true;
    gameModeIntent = true;
    gameModeGraceUntil = performance.now() + 2500;

    gameSurface.focus({ preventScroll: true });
    syncVirtualMouseFromClient(
      virtualMouseX || window.innerWidth / 2,
      virtualMouseY || window.innerHeight / 2
    );

    // Request fullscreen and pointer lock in the same user-gesture turn.
    // Awaiting between the two calls expires user activation and makes lock fail,
    // which previously triggered exitGameModeInternal() and kicked the user out.
    try {
      const fsPromise = requestGameModeFullscreen();
      if (fsPromise && typeof fsPromise.catch === "function") {
        fsPromise.catch((error) => noteGameModeError("fullscreen", error));
      }
    } catch (error) {
      noteGameModeError("fullscreen", error);
    }

    try {
      const lockPromise = requestGameModePointerLock();
      if (lockPromise && typeof lockPromise.catch === "function") {
        lockPromise.catch((error) => noteGameModeError("lock", error));
      }
    } catch (error) {
      noteGameModeError("lock", error);
    }

    window.setTimeout(() => {
      if (!gameModeBusy) return;
      gameModeBusy = false;
      if (!isGameModeFullscreen() && !isPointerLocked()) {
        gameModeIntent = false;
      }
      updateGameModeUi();
    }, 2600);

    updateGameModeUi();
  }

  function completeGameModeEnter() {
    gameModeBusy = false;
    gameModeIntent = true;
    updateGameModeUi();
  }

  async function exitGameMode() {
    if (gameModeBusy) return;
    if (!gameModeIntent && !isPointerLocked() && !isGameModeFullscreen()) return;
    gameModeBusy = true;
    gameModeIntent = false;
    gameModeGraceUntil = 0;
    try {
      await exitGameModeInternal();
      releasePressedKeys();
    } finally {
      gameModeBusy = false;
      updateGameModeUi();
    }
  }

  function toggleGameMode() {
    const now = performance.now();
    if (gameModeBusy || now - lastGameModeToggleAt < 400) return;
    lastGameModeToggleAt = now;
    if (gameModeIntent || isPointerLocked() || isGameModeFullscreen()) {
      void exitGameMode();
    } else {
      enterGameMode();
    }
  }

  function onPointerLockChange() {
    if (isPointerLocked()) {
      releasePressedKeys();
      centerVirtualMouse();
      const { x, y } = mapMouse({ clientX: virtualMouseX, clientY: virtualMouseY });
      remoteSentGameX = x;
      remoteSentGameY = y;
      sendInput({ type: "mousemove", x, y });
      completeGameModeEnter();
      return;
    }

    releasePressedKeys();
    updateGameModeUi();
  }

  function onFullscreenChange() {
    if (isGameModeFullscreen()) {
      completeGameModeEnter();
      if (!isPointerLocked() && performance.now() < gameModeGraceUntil) {
        try {
          const lockPromise = requestGameModePointerLock();
          if (lockPromise && typeof lockPromise.catch === "function") {
            lockPromise.catch((error) => noteGameModeError("lock", error));
          }
        } catch (error) {
          noteGameModeError("lock", error);
        }
      }
      updateGameModeUi();
      return;
    }

    if (performance.now() < gameModeGraceUntil && gameModeIntent) {
      try {
        const fsPromise = requestGameModeFullscreen();
        if (fsPromise && typeof fsPromise.catch === "function") {
          fsPromise.catch((error) => noteGameModeError("fullscreen", error));
        }
      } catch (error) {
        noteGameModeError("fullscreen", error);
      }
      updateGameModeUi();
      return;
    }

    if (!gameModeIntent) {
      updateGameModeUi();
      return;
    }

    if (isPointerLocked()) {
      document.exitPointerLock();
    }
    gameModeIntent = false;
    gameModeBusy = false;
    releasePressedKeys();
    updateGameModeUi();
  }

  function bindGameMode() {
    gameModeButton?.addEventListener("click", (event) => {
      event.stopPropagation();
      void toggleGameMode();
    });
    canvas.addEventListener("dblclick", (event) => {
      event.preventDefault();
      void toggleGameMode();
    });
    for (const eventName of ["fullscreenchange", "webkitfullscreenchange"]) {
      document.addEventListener(eventName, onFullscreenChange);
    }
    document.addEventListener("pointerlockchange", onPointerLockChange);
    document.addEventListener("pointerlockerror", () => {
      noteGameModeError("lock", "blocked by browser");
      gameModeBusy = false;
      updateGameModeUi();
    });
    window.addEventListener("keydown", handleGameModeShortcut, true);
    updateGameModeUi();
  }

  function isGameModeShortcut(event) {
    return Boolean(event.ctrlKey && event.altKey && event.code === "KeyL");
  }

  function isModifierKey(key) {
    return key === "Control" || key === "Alt" || key === "Meta" || key === "Shift";
  }

  function handleGameModeShortcut(event) {
    if (!isGameModeShortcut(event)) return;
    event.preventDefault();
    event.stopPropagation();
    void toggleGameMode();
  }

  function handleKeyDown(e) {
    if (e.repeat || isGameModeShortcut(e)) return;
    if (pressedKeys.has(e.key)) {
      e.preventDefault();
      return;
    }
    pressedKeys.add(e.key);
    sendInput({ type: "keydown", key: e.key });
    e.preventDefault();
  }

  function handleKeyUp(e) {
    if (isGameModeShortcut(e)) return;
    if (pressedKeys.has(e.key)) {
      pressedKeys.delete(e.key);
      sendInput({ type: "keyup", key: e.key });
    }
    if (isModifierKey(e.key) && pressedKeys.size > 0) {
      releasePressedKeys();
    }
    e.preventDefault();
  }

  function shouldHandlePointerEvent(event) {
    if (isPointerLocked()) return true;
    const target = event.target;
    if (!(target instanceof Node)) return false;
    return gameSurface.contains(target);
  }

  function handlePointerMove(e) {
    if (!shouldHandlePointerEvent(e)) return;
    if (isPointerLocked()) {
      applyPointerDelta(e);
    } else {
      syncVirtualMouseFromClient(e.clientX, e.clientY);
    }
    updateCursorOverlay();
    const now = performance.now();
    if (now - lastMoveAt < moveInterval) return;
    lastMoveAt = now;
    const { x, y } = mapMouse(e);
    sendInput({ type: "mousemove", x, y });
  }

  function handlePointerDown(e) {
    if (!shouldHandlePointerEvent(e)) return;
    gameSurface.focus({ preventScroll: true });
    if (!isPointerLocked() && e.pointerId !== undefined && canvas.setPointerCapture) {
      try {
        canvas.setPointerCapture(e.pointerId);
      } catch {
        // Pointer capture can fail if the pointer is already released.
      }
    }
    const { x, y } = mapMouse(e);
    sendInput({ type: "mousedown", x, y, button: e.button + 1 });
    e.preventDefault();
  }

  function handlePointerUp(e) {
    if (!shouldHandlePointerEvent(e)) return;
    const { x, y } = mapMouse(e);
    sendInput({ type: "mouseup", x, y, button: e.button + 1 });
    e.preventDefault();
  }

  function handlePointerWheel(e) {
    if (!shouldHandlePointerEvent(e)) return;
    sendInput({ type: "wheel", deltaY: e.deltaY });
    e.preventDefault();
  }

  function bindInput() {
    canvas.tabIndex = 0;
    gameSurface.addEventListener("contextmenu", (e) => e.preventDefault());

    const moveEvent = window.PointerEvent ? "pointermove" : "mousemove";
    const downEvent = window.PointerEvent ? "pointerdown" : "mousedown";
    const upEvent = window.PointerEvent ? "pointerup" : "mouseup";

    // Pointer lock is on #gameSurface, so locked events target document — capture here.
    document.addEventListener(moveEvent, handlePointerMove, true);
    document.addEventListener(downEvent, handlePointerDown, true);
    document.addEventListener(upEvent, handlePointerUp, true);
    document.addEventListener("wheel", handlePointerWheel, { capture: true, passive: false });
    window.addEventListener("keydown", handleKeyDown);
    window.addEventListener("keyup", handleKeyUp);
    window.addEventListener("blur", releasePressedKeys);
    window.addEventListener("pagehide", releasePressedKeys);
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) {
        releasePressedKeys();
      }
    });
  }

  function bindSettingsUi() {
    panelHeader.addEventListener("click", () => {
      controlPanel.classList.toggle("collapsed");
      panelToggle.textContent = controlPanel.classList.contains("collapsed") ? "▼" : "▲";
    });
    controlPanel.addEventListener("dblclick", (event) => event.stopPropagation());
    for (const el of [
      videoQualityEl,
      videoCodecEl,
      videoBitrateEl,
      audioEncoderEl,
      audioBitrateEl,
      audioQualityEl,
      inputMoveHzEl,
    ]) {
      el.addEventListener("change", () => {
        const settings = currentSettingsFromUi();
        saveSettings(settings);
        moveInterval = 1000 / Number(settings.inputMoveHz || 60);
        scheduleTransportApply();
      });
    }
  }

  function checkStreamWatchdog() {
    if (connectionState !== "streaming" || !ws || ws.readyState !== WebSocket.OPEN) return;
    const now = performance.now();
    const sinceReady = now - streamStatsStartedAt;
    if (sinceReady < STREAM_STALL_MS) return;
    const frameIdle = lastVideoFrameAt ? now - lastVideoFrameAt : sinceReady;
    const rxIdle = lastVideoMessageAt ? now - lastVideoMessageAt : sinceReady;
    if (frameIdle < STREAM_STALL_MS && rxIdle < STREAM_STALL_MS) return;
    streamStalls += 1;
    lastVideoFrameAt = 0;
    lastVideoMessageAt = 0;
    updateTransportStatus([
      `stream stall: frameIdle=${Math.round(frameIdle)}ms rxIdle=${Math.round(rxIdle)}ms — reconnecting`,
    ]);
    releasePressedKeys();
    ws.close();
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
    applyingTransport = false;
    appliedSettings = null;
    if (applyTransportTimer) {
      clearTimeout(applyTransportTimer);
      applyTransportTimer = null;
    }
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
      ws.send(JSON.stringify({
        type: "start",
        settings: startSettings,
      }));
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
        connectionState = "streaming";
        applyingTransport = false;
        pendingSettings = false;
        pendingNotice.classList.remove("visible");
        videoBytes = 0;
        streamStatsStartedAt = performance.now();
        lastVideoFrameAt = 0;
        lastVideoMessageAt = 0;
        if (msg.reason === "helper_restart" || msg.reason === "reconfigure") {
          resetVideoDecoder();
          resetAudioPlayback();
          void ensureDecoders();
        }
        if (msg.width && msg.height) {
          syncStreamDimensions(msg.width, msg.height);
        }
        if (msg.nativeWidth && msg.nativeHeight) {
          nativeWidth = msg.nativeWidth;
          nativeHeight = msg.nativeHeight;
        }
        if (msg.active) {
          activeVideoCodec = msg.active.videoCodec || "H264";
          activeAudioBitrate = Number(msg.active.audioBitrate || 64000);
          moveInterval = 1000 / Number(msg.active.inputMoveHz || 60);
          setStreamFps(msg.active.videoFps || streamFps);
          syncUiFromActive(msg.active);
          saveSettings(currentSettingsFromUi());
          appliedSettings = transportSettingsSnapshot(currentSettingsFromUi());
        }
        activeTransport = msg.transport || null;
        serverFallbacks = msg.fallbacks || [];
        updateAvailability(msg.available);
        updateTransportStatus();
        if (applyTransportTimer) {
          clearTimeout(applyTransportTimer);
          applyTransportTimer = null;
        }
        return;
      }
      if (msg.type === "video") decodeVideo(msg);
      if (msg.type === "audio") decodeAudio(msg);
    };
    ws.onclose = () => {
      connectionState = "reconnecting";
      configured = false;
      resetAudioPlayback();
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
  bindGameMode();
  bindSettingsUi();
  applySettingsToUi(loadSettings());
  updateTransportStatus();
  setInterval(updateTransportStatus, 1000);
  setInterval(checkStreamWatchdog, 2000);
})();
