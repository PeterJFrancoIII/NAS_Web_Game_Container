(() => {
  "use strict";

  const SETTINGS_KEY = "ra2UltraTransportSettings";
  const SETTINGS_VERSION = 47;
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
  const overlayConnectButton = document.getElementById("overlayConnectButton");
  const overlayStep1 = document.getElementById("overlayStep1");
  const overlayHint = document.getElementById("overlayHint");
  const gamePicker = document.getElementById("gamePicker");
  const gamePickerTitle = document.getElementById("gamePickerTitle");
  const gameSessionStatus = document.getElementById("gameSessionStatus");
  const gamePickerButtons = document.getElementById("gamePickerButtons");
  const watchPanel = document.getElementById("watchPanel");
  const watchStatus = document.getElementById("watchStatus");
  const watchStreamButton = document.getElementById("watchStreamButton");
  const switchGameButton = document.getElementById("switchGameButton");
  const activeGameStatus = document.getElementById("activeGameStatus");
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
  let virtualGameX = 0;
  let virtualGameY = 0;
  let remoteSentGameX = 0;
  let remoteSentGameY = 0;
  let gameModeIntent = false;
  let gameModeBusy = false;
  let gameModeGraceUntil = 0;
  let lastGameModeToggleAt = 0;
  const STREAM_STALL_MS = 8000;
  const activeAudioSources = new Set();
  let availableGames = [];
  let gameLauncherEnabled = false;
  let currentGameSession = null;
  let clientRole = "pending";
  let controllerActive = false;
  let controllerStreaming = false;
  let spectatorCount = 0;
  let selectedGameId = null;
  let pendingGameSelectResolve = null;
  let pendingGameSelectReject = null;
  let connectTimeoutTimer = null;
  const CONNECT_TIMEOUT_MS = 10000;

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
    if (clientRole !== "controller") return;
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
    if (overlayHint) {
      overlayHint.textContent = text || "";
      overlayHint.hidden = !text;
    } else if (overlayConnectButton) {
      overlayConnectButton.textContent = text;
    } else if (overlayStatus) {
      overlayStatus.textContent = text;
    }
    if (overlay) overlay.classList.remove("hidden");
  }

  function showOverlayStep1() {
    if (overlay) overlay.classList.remove("picker-open");
    if (overlayStep1) overlayStep1.hidden = false;
    if (overlayConnectButton) overlayConnectButton.hidden = false;
    if (overlayHint) {
      overlayHint.textContent = "";
      overlayHint.hidden = true;
    }
  }

  function showOverlayStep2() {
    if (overlay) overlay.classList.add("picker-open");
    if (overlayStep1) overlayStep1.hidden = true;
    if (overlayConnectButton) {
      overlayConnectButton.hidden = true;
      overlayConnectButton.disabled = false;
    }
    if (overlayHint) overlayHint.hidden = true;
  }

  function setConnectButtonBusy(busy) {
    if (overlayConnectButton) overlayConnectButton.disabled = busy;
  }

  function clearConnectTimeout() {
    if (connectTimeoutTimer) {
      clearTimeout(connectTimeoutTimer);
      connectTimeoutTimer = null;
    }
  }

  function startConnectTimeout() {
    clearConnectTimeout();
    connectTimeoutTimer = setTimeout(() => {
      connectTimeoutTimer = null;
      if (connectionState !== "connecting") return;
      const socket = ws;
      if (socket) {
        detachSocketHandlers(socket);
        socket.close();
      }
      ws = null;
      handleConnectFailure("Timed out waiting for game list");
    }, CONNECT_TIMEOUT_MS);
  }

  function hideOverlay() {
    if (overlay) overlay.classList.add("hidden");
    gamePicker.classList.remove("visible");
    watchPanel.classList.remove("visible");
  }

  function setSessionStatus(text) {
    if (activeGameStatus) {
      activeGameStatus.textContent = text;
    }
  }

  function showClickToConnect() {
    clearConnectTimeout();
    connectionState = "idle";
    gamePicker.classList.remove("visible");
    watchPanel.classList.remove("visible");
    showOverlayStep1();
    setConnectButtonBusy(false);
    if (overlayConnectButton) overlayConnectButton.textContent = "Click to choose a game";
    setStatus("");
    setSessionStatus("No game session reported.");
  }

  function applySessionPresence(msg) {
    if (typeof msg.controllerActive === "boolean") controllerActive = msg.controllerActive;
    if (typeof msg.controllerStreaming === "boolean") controllerStreaming = msg.controllerStreaming;
    if (typeof msg.spectatorCount === "number") spectatorCount = msg.spectatorCount;
    if (msg.role) clientRole = msg.role;
    updateSpectatorUi();
  }

  function updateSpectatorUi() {
    const spectator = clientRole === "spectator";
    if (switchGameButton) {
      switchGameButton.hidden = spectator;
    }
    if (activeGameStatus && spectator) {
      activeGameStatus.textContent = controllerStreaming
        ? `Watching live stream (${spectatorCount} viewer${spectatorCount === 1 ? "" : "s"})`
        : "Waiting for the active player to start streaming…";
    }
    controlPanel.classList.toggle("spectator-mode", spectator);
  }

  function updateWatchPanel(session, presence) {
    const gameTitle = session && session.title ? session.title : (session && session.id ? session.id : "a game");
    const streaming = presence && presence.controllerStreaming;
    if (watchStatus) {
      if (streaming) {
        watchStatus.textContent = `A player is running ${gameTitle}. You can watch video and audio, but not control the game.`;
      } else {
        watchStatus.textContent = `A player is connected and preparing ${gameTitle}. Watch now and the stream will begin when they connect.`;
      }
    }
  }

  function showWatchPanel(games, session, presence) {
    gamePicker.classList.remove("visible");
    updateWatchPanel(session || currentGameSession, presence || {
      controllerActive,
      controllerStreaming,
      spectatorCount,
    });
    watchPanel.classList.add("visible");
    showOverlayStep2();
    clearConnectTimeout();
    setConnectButtonBusy(false);
    if (presence && presence.controllerStreaming) {
      setStatus("Another player is in control — read below, then click Watch stream");
    } else {
      setStatus("Another player is in control — read below, then click Watch stream when ready");
    }
  }

  function updateActiveGameStatus() {
    if (!activeGameStatus) return;
    if (currentGameSession && currentGameSession.phase === "running" && currentGameSession.id) {
      activeGameStatus.textContent = `In session: ${currentGameSession.title || currentGameSession.id}`;
    } else if (currentGameSession && currentGameSession.phase === "switching" && currentGameSession.id) {
      activeGameStatus.textContent = `Switching to ${currentGameSession.title || currentGameSession.id}…`;
    } else {
      activeGameStatus.textContent = "Waiting at game menu.";
    }
  }

  function showGamePicker(games, session) {
    gamePickerButtons.textContent = "";
    const activeId = session && session.phase === "running" ? session.id : null;
    if (session && session.phase === "running" && session.id) {
      gamePickerTitle.textContent = "Games";
      gameSessionStatus.hidden = false;
      gameSessionStatus.textContent = `Currently in session: ${session.title || session.id}`;
    } else if (session && session.phase === "switching" && session.id) {
      gamePickerTitle.textContent = "Games";
      gameSessionStatus.hidden = false;
      gameSessionStatus.textContent = `Switching to ${session.title || session.id}…`;
    } else {
      gamePickerTitle.textContent = "Choose a game";
      gameSessionStatus.hidden = true;
      gameSessionStatus.textContent = "";
    }
    for (const game of games) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "game-pick-btn";
      if (activeId && game.id === activeId) {
        btn.classList.add("active");
      }
      btn.textContent = game.title || game.id;
      btn.dataset.gameId = game.id;
      btn.addEventListener("click", (event) => {
        event.stopPropagation();
        void pickGame(game.id);
      });
      gamePickerButtons.appendChild(btn);
    }
    gamePicker.classList.add("visible");
    showOverlayStep2();
    clearConnectTimeout();
    setConnectButtonBusy(false);
    if (activeId) {
      gamePickerTitle.textContent = `Select a game — ${session.title || session.id} is running`;
    }
    updateActiveGameStatus();
  }

  function openSwitchGameOverlay() {
    if (!gameLauncherEnabled || !availableGames.length) return;
    if (overlay) overlay.classList.remove("hidden");
    showGamePicker(availableGames, currentGameSession);
  }

  function setGamePickerBusy(busy) {
    for (const btn of gamePickerButtons.querySelectorAll(".game-pick-btn")) {
      btn.disabled = busy;
    }
  }

  function sendSelectGame(gameId) {
    return new Promise((resolve, reject) => {
      if (!ws || ws.readyState !== WebSocket.OPEN) {
        reject(new Error("not connected"));
        return;
      }
      pendingGameSelectResolve = resolve;
      pendingGameSelectReject = reject;
      ws.send(JSON.stringify({ type: "selectGame", game: gameId }));
    });
  }

  async function pickGame(gameId) {
    if (!gameId) return;
    const sameRunning =
      currentGameSession &&
      currentGameSession.phase === "running" &&
      currentGameSession.id === gameId;
    if (sameRunning && connectionState === "streaming") {
      hideOverlay();
      return;
    }
    const switchingStream = connectionState === "streaming" && !sameRunning;
    setGamePickerBusy(true);
    if (switchingStream) {
      setStatus(`Switching to ${gameId}…`);
      releasePressedKeys();
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: "stop" }));
      }
      resetVideoDecoder();
      resetAudioPlayback();
      connectionState = "connecting";
    } else if (sameRunning) {
      setStatus(`Connecting to ${currentGameSession.title || gameId}…`);
    } else if (currentGameSession && currentGameSession.phase === "running" && currentGameSession.id) {
      setStatus(`Switching from ${currentGameSession.title || currentGameSession.id} to ${gameId}…`);
    } else {
      setStatus(`Starting ${gameId}…`);
    }
    try {
      const result = await sendSelectGame(gameId);
      selectedGameId = result.game || gameId;
      currentGameSession = result.currentGame || {
        phase: "running",
        id: selectedGameId,
        title: gameId,
      };
      updateActiveGameStatus();
      await startStreamAfterGameSelect();
    } catch (error) {
      selectedGameId = null;
      setGamePickerBusy(false);
      setStatus(error && error.message ? error.message : "Game selection failed");
    }
  }

  async function ensureGameSelected(games, launcherEnabled, session, presence) {
    if (!launcherEnabled || !games.length) {
      selectedGameId = null;
      return true;
    }
    currentGameSession = session || currentGameSession;
    applySessionPresence(presence || {});
    if (controllerActive && clientRole !== "controller") {
      showWatchPanel(games, currentGameSession, presence);
      return false;
    }
    watchPanel.classList.remove("visible");
    showGamePicker(games, currentGameSession);
    return false;
  }

  async function watchStream() {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    clientRole = "spectator";
    setStatus("Joining as spectator…");
    unlockAudio();
    ws.send(JSON.stringify({ type: "watch" }));
  }

  async function startStreamAfterGameSelect() {
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      throw new Error("not connected");
    }
    clientRole = "controller";
    const settings = loadSettings();
    const startSettings = await browserCompatibleSettings(settings);
    await ensureDecoders();
    connectionState = "connected";
    updateTransportStatus();
    hideOverlay();
    ws.send(JSON.stringify({
      type: "start",
      settings: startSettings,
    }));
    startPingTimer();
  }

  function handleSelectGameResult(msg) {
    const resolve = pendingGameSelectResolve;
    const reject = pendingGameSelectReject;
    pendingGameSelectResolve = null;
    pendingGameSelectReject = null;
    applySessionPresence(msg);
    if (msg.currentGame) {
      currentGameSession = msg.currentGame;
      updateActiveGameStatus();
    }
    if (msg.ok && msg.role) {
      clientRole = msg.role;
    }
    if (!resolve) return;
    if (msg.ok) {
      resolve(msg);
      return;
    }
    if (msg.error && String(msg.error).includes("Another player is in control")) {
      showWatchPanel(availableGames, currentGameSession, msg);
    }
    reject(new Error(msg.error || "Game selection rejected"));
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

  async function resolveActiveVideoDecoderCodec(videoCodec, { recordFallbacks = false } = {}) {
    const requestedVideo = String(videoCodec || "H264").toUpperCase();
    const resolution = `${streamWidth}x${streamHeight}`;
    const videoDecoderCodec = await supportedVideoDecoderCodec(requestedVideo, resolution);
    if (videoDecoderCodec) {
      activeVideoDecoderCodec = videoDecoderCodec;
      return requestedVideo;
    }
    if (requestedVideo !== "H264") {
      const fallbackOrder = requestedVideo === "H265_10" ? ["H265", "H264"] : ["H264"];
      for (const fallback of fallbackOrder) {
        const fallbackDecoderCodec = await supportedVideoDecoderCodec(fallback, resolution);
        if (!fallbackDecoderCodec) continue;
        activeVideoDecoderCodec = fallbackDecoderCodec;
        if (recordFallbacks) {
          browserFallbacks.push({
            field: "videoCodec",
            requested: requestedVideo,
            active: fallback,
            reason:
              requestedVideo === "H265_10" && fallback === "H265"
                ? "10-bit HEVC VideoDecoder unsupported in this browser"
                : "HEVC VideoDecoder unsupported in this browser",
          });
        }
        return fallback;
      }
    }
    activeVideoDecoderCodec = VIDEO_DECODER_CODECS.H264[0];
    return "H264";
  }

  async function browserCompatibleSettings(settings) {
    browserFallbacks = [];
    const compatible = { ...settings };
    compatible.videoCodec = await resolveActiveVideoDecoderCodec(compatible.videoCodec, {
      recordFallbacks: true,
    });
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

  async function applyStreamReady(msg) {
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
      activeAudioEncoder = msg.active.audioEncoder || activeAudioEncoder;
      activeAudioRate = Number(msg.active.audioQuality || activeAudioRate);
      moveInterval = 1000 / Number(msg.active.inputMoveHz || 60);
      setStreamFps(msg.active.videoFps || streamFps);
      activeVideoCodec = await resolveActiveVideoDecoderCodec(activeVideoCodec, {
        recordFallbacks: true,
      });
      if (clientRole === "controller") {
        syncUiFromActive(msg.active);
        saveSettings(currentSettingsFromUi());
        appliedSettings = transportSettingsSnapshot(currentSettingsFromUi());
      }
    }
    resetVideoDecoder();
    resetAudioPlayback();
    await ensureDecoders();
  }

  function setStreamFps(fps) {
    streamFps = Math.max(1, Number(fps) || 24);
    frameIntervalMs = 1000 / streamFps;
    nextPresentAt = 0;
  }

  function startPingTimer() {
    if (pingTimer) clearInterval(pingTimer);
    pingTimer = null;
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    pingTimer = setInterval(() => {
      if (!ws || ws.readyState !== WebSocket.OPEN) return;
      const t0 = performance.now();
      ws.send(JSON.stringify({ type: "ping", t: t0 }));
    }, 5000);
  }

  function recoverVideoPresentation({ forcePresent = false } = {}) {
    if (presentHandle !== null) {
      if (typeof canvas.cancelVideoFrameCallback === "function") {
        try {
          canvas.cancelVideoFrameCallback(presentHandle);
        } catch {
          // Callback may already have fired or been cancelled by the browser.
        }
      } else {
        cancelAnimationFrame(presentHandle);
      }
      presentHandle = null;
    }
    if (!pendingVideoFrame) return;
    if (forcePresent) {
      nextPresentAt = 0;
      onPresentFrame(performance.now());
      return;
    }
    scheduleVideoPresent();
  }

  function onDisplayLayoutChange() {
    requestAnimationFrame(() => {
      recoverVideoPresentation({ forcePresent: true });
      updateCursorOverlay();
    });
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
    if (!videoDecoder) return;
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
    if (clientRole !== "controller") return;
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
    gameSurface.style.setProperty("--stream-ar-w", String(w));
    gameSurface.style.setProperty("--stream-ar-h", String(h));
  }

  function canvasContentRect() {
    return canvas.getBoundingClientRect();
  }

  function activeFullscreenElement() {
    return document.fullscreenElement || document.webkitFullscreenElement || null;
  }

  function isPointerLocked() {
    return document.pointerLockElement === gameSurface
      || document.pointerLockElement === canvas;
  }

  function isGameModeFullscreen() {
    const fs = activeFullscreenElement();
    return fs === gameSurface || fs === canvas;
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

  function streamGameSize() {
    return {
      w: streamWidth || canvas.width,
      h: streamHeight || canvas.height,
    };
  }

  function gameCoordsFromClient(clientX, clientY) {
    const rect = canvasContentRect();
    const { w, h } = streamGameSize();
    const x = Math.round(clamp((clientX - rect.left) / rect.width, 0, 1) * (w - 1));
    const y = Math.round(clamp((clientY - rect.top) / rect.height, 0, 1) * (h - 1));
    return { x, y };
  }

  function syncVirtualMouseFromClient(clientX, clientY) {
    const rect = canvasContentRect();
    virtualMouseX = clamp(clientX, rect.left, rect.left + rect.width - 0.001);
    virtualMouseY = clamp(clientY, rect.top, rect.top + rect.height - 0.001);
  }

  function syncVirtualGameFromClient(clientX, clientY) {
    const coords = gameCoordsFromClient(clientX, clientY);
    virtualGameX = coords.x;
    virtualGameY = coords.y;
    syncVirtualMouseFromGame();
  }

  function syncVirtualMouseFromGame() {
    const screen = gameCoordsToScreen(virtualGameX, virtualGameY);
    virtualMouseX = screen.clientX;
    virtualMouseY = screen.clientY;
  }

  function centerVirtualMouse() {
    const rect = canvasContentRect();
    virtualMouseX = rect.left + rect.width / 2;
    virtualMouseY = rect.top + rect.height / 2;
    syncVirtualGameFromClient(virtualMouseX, virtualMouseY);
  }

  function centerVirtualGame() {
    const { w, h } = streamGameSize();
    virtualGameX = (w - 1) / 2;
    virtualGameY = (h - 1) / 2;
    syncVirtualMouseFromGame();
  }

  function applyPointerDelta(event) {
    const { w, h } = streamGameSize();
    // Pointer lock reports hardware deltas in CSS pixels. Map 1:1 into game space so
    // sensitivity does not drop when the canvas scales up in fullscreen.
    virtualGameX = clamp(virtualGameX + event.movementX, 0, w - 1);
    virtualGameY = clamp(virtualGameY + event.movementY, 0, h - 1);
    syncVirtualMouseFromGame();
  }

  function pointerMoveEvents(event) {
    if (typeof event.getCoalescedEvents === "function") {
      const coalesced = event.getCoalescedEvents();
      if (coalesced.length > 0) return coalesced;
    }
    return [event];
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
      return {
        x: Math.round(virtualGameX),
        y: Math.round(virtualGameY),
      };
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
    if (!virtualMouseX || !virtualMouseY) {
      centerVirtualGame();
    } else {
      syncVirtualGameFromClient(virtualMouseX, virtualMouseY);
    }

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
      onDisplayLayoutChange();
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
      centerVirtualGame();
      remoteSentGameX = Math.round(virtualGameX);
      remoteSentGameY = Math.round(virtualGameY);
      sendInput({ type: "mousemove", x: remoteSentGameX, y: remoteSentGameY });
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
    const target = event.target;
    if (!(target instanceof Node)) return false;
    if (overlay && overlay.contains(target)) return false;
    if (controlPanel && controlPanel.contains(target)) return false;
    if (isPointerLocked()) return true;
    return gameSurface.contains(target);
  }

  function handlePointerMove(e) {
    if (!shouldHandlePointerEvent(e)) return;
    if (isPointerLocked()) {
      for (const ev of pointerMoveEvents(e)) {
        applyPointerDelta(ev);
      }
    } else {
      syncVirtualMouseFromClient(e.clientX, e.clientY);
      syncVirtualGameFromClient(e.clientX, e.clientY);
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
    if (gameModeIntent && !isPointerLocked()) {
      try {
        const lockPromise = requestGameModePointerLock();
        if (lockPromise && typeof lockPromise.catch === "function") {
          lockPromise.catch((error) => noteGameModeError("lock", error));
        }
      } catch (error) {
        noteGameModeError("lock", error);
      }
    }
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

  function detachSocketHandlers(socket) {
    if (!socket) return;
    socket.onopen = null;
    socket.onmessage = null;
    socket.onclose = null;
    socket.onerror = null;
  }

  function beginConnectAttempt() {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    connectionState = "connecting";
    pendingSettings = false;
    applyingTransport = false;
    appliedSettings = null;
    selectedGameId = null;
    clientRole = "pending";
    pendingGameSelectResolve = null;
    pendingGameSelectReject = null;
    gamePicker.classList.remove("visible");
    watchPanel.classList.remove("visible");
    if (applyTransportTimer) {
      clearTimeout(applyTransportTimer);
      applyTransportTimer = null;
    }
    pendingNotice.classList.remove("visible");
    updateTransportStatus();
    setStatus("Opening game selection…");
    setSessionStatus("Connecting…");
    setConnectButtonBusy(true);
    startConnectTimeout();
  }

  function handleConnectFailure(message) {
    clearConnectTimeout();
    connectionState = "idle";
    gamePicker.classList.remove("visible");
    watchPanel.classList.remove("visible");
    showOverlayStep1();
    setConnectButtonBusy(false);
    setSessionStatus("No game session reported.");
    setStatus(`${message} — click to try again`);
  }

  function bindSocketHandlers(socket) {
    socket.onopen = () => {
      if (ws !== socket) return;
    };
    socket.onmessage = async (ev) => {
      if (ws !== socket) return;
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
      if (msg.type === "selectGameResult") {
        handleSelectGameResult(msg);
        return;
      }
      if (msg.type === "controllerBusy") {
        applySessionPresence(msg);
        showWatchPanel(availableGames, currentGameSession, msg);
        connectionState = "connecting";
        return;
      }
      if (msg.type === "waitingForController") {
        applySessionPresence(msg);
        currentGameSession = msg.currentGame || currentGameSession;
        updateActiveGameStatus();
        setStatus("Waiting for the active player to start streaming…");
        return;
      }
      if (msg.type === "controllerLeft") {
        applySessionPresence(msg);
        if (clientRole === "spectator") {
          connectionState = "connecting";
          resetVideoDecoder();
          resetAudioPlayback();
          showWatchPanel(availableGames, currentGameSession, msg);
          setStatus("The active player disconnected. Waiting for a new session…");
        }
        return;
      }
      if (msg.type === "role") {
        applySessionPresence(msg);
        return;
      }
      if (msg.type === "hello") {
        try {
          if (msg.defaults) {
            applySettingsToUi({ ...DEFAULT_SETTINGS, ...loadSettings() });
          }
          updateAvailability(msg.available);
          availableGames = Array.isArray(msg.availableGames) ? msg.availableGames : [];
          gameLauncherEnabled = Boolean(msg.gameLauncherEnabled);
          currentGameSession = msg.currentGame || null;
          applySessionPresence(msg);
          updateActiveGameStatus();
          updateTransportStatus();
          if (connectionState !== "connecting") return;
          const ready = await ensureGameSelected(
            availableGames,
            gameLauncherEnabled,
            currentGameSession,
            msg,
          );
          clearConnectTimeout();
          if (ready) {
            await startStreamAfterGameSelect();
          } else {
            setConnectButtonBusy(false);
          }
        } catch (error) {
          clearConnectTimeout();
          showClickToConnect();
          const message = error && error.message ? error.message : "Game selection failed";
          setStatus(`${message} — click to try again`);
        }
        return;
      }
      if (msg.type === "ready") {
        if (msg.role) clientRole = msg.role;
        applySessionPresence(msg);
        updateSpectatorUi();
        connectionState = "streaming";
        applyingTransport = false;
        pendingSettings = false;
        pendingNotice.classList.remove("visible");
        videoBytes = 0;
        streamStatsStartedAt = performance.now();
        lastVideoFrameAt = 0;
        lastVideoMessageAt = 0;
        if (msg.reason === "watch" || msg.reason === "start") {
          hideOverlay();
        } else if (clientRole === "spectator") {
          hideOverlay();
        }
        await applyStreamReady(msg);
        if (clientRole === "spectator" || clientRole === "controller") {
          startPingTimer();
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
    socket.onclose = () => {
      if (ws !== socket) return;
      clearConnectTimeout();
      const resumeStream = connectionState === "streaming" || Boolean(selectedGameId);
      configured = false;
      resetAudioPlayback();
      pendingGameSelectResolve = null;
      pendingGameSelectReject = null;
      gamePicker.classList.remove("visible");
      watchPanel.classList.remove("visible");
      ws = null;
      if (resumeStream) {
        connectionState = "reconnecting";
        setStatus("Disconnected — reconnecting…");
        scheduleReconnect();
        return;
      }
      showClickToConnect();
    };
    socket.onerror = () => {
      if (ws !== socket) return;
      clearConnectTimeout();
      setSessionStatus("Connection error");
      setConnectButtonBusy(false);
      if (connectionState === "connecting") {
        setStatus("Connection error — click to try again");
        connectionState = "idle";
        showOverlayStep1();
      }
    };
  }

  async function connect() {
    if (connectionState === "connecting") return;
    beginConnectAttempt();
    try {
      try {
        unlockAudio();
      } catch (error) {
        console.error("audio unlock", error);
      }

      const previous = ws;
      if (previous) {
        releasePressedKeys();
        detachSocketHandlers(previous);
        previous.close();
      }
      ws = null;

      resetVideoDecoder();
      resetAudioDecoder();

      const settings = loadSettings();
      applySettingsToUi(settings);
      saveSettings(settings);
      updateTransportStatus();

      const socket = new WebSocket(wsUrl());
      ws = socket;
      bindSocketHandlers(socket);
    } catch (error) {
      const message = error && error.message ? error.message : "Connection failed";
      handleConnectFailure(message);
    }
  }

  function requestConnectFromOverlay(event) {
    if (event && event.target && event.target.closest(".game-pick-btn")) return;
    if (event && event.target && event.target.closest("#watchStreamButton")) return;
    if (connectionState === "connecting" || connectionState === "reconnecting") return;
    if (watchPanel.classList.contains("visible") && connectionState === "streaming") {
      hideOverlay();
      return;
    }
    if (ws && ws.readyState === WebSocket.OPEN && (gamePicker.classList.contains("visible") || watchPanel.classList.contains("visible"))) {
      return;
    }
    try {
      unlockAudio();
    } catch (error) {
      console.error("audio unlock", error);
    }
    void connect();
  }

  if (overlay) {
    overlay.addEventListener("click", requestConnectFromOverlay);
  }
  overlayConnectButton?.addEventListener("click", (event) => {
    event.stopPropagation();
    requestConnectFromOverlay(event);
  });
  if (watchStreamButton) {
    watchStreamButton.addEventListener("click", (event) => {
      event.stopPropagation();
      void watchStream();
    });
  }
  if (switchGameButton) {
    switchGameButton.addEventListener("click", (event) => {
      event.stopPropagation();
      openSwitchGameOverlay();
    });
  }
  bindInput();
  bindGameMode();
  bindSettingsUi();
  window.addEventListener("resize", onDisplayLayoutChange);
  syncStreamDimensions(streamWidth, streamHeight);
  applySettingsToUi(loadSettings());
  showClickToConnect();
  updateTransportStatus();
  setInterval(updateTransportStatus, 1000);
  setInterval(checkStreamWatchdog, 2000);
})();
