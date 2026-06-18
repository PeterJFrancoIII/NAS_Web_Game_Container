(() => {
  "use strict";

  const Ice = window.Ra2WebRtcIceUtils;
  if (!Ice) {
    throw new Error("webrtc-ice-utils.js must load before ultra-play.js");
  }

  const SETTINGS_KEY = "ra2UltraTransportSettings";
  const SETTINGS_VERSION = 74;
  const OPUS_NATIVE_RATE = 48000;
  const AUDIO_START_LEAD_S = 0.05;
  const DEFAULT_SETTINGS = {
    settingsVersion: SETTINGS_VERSION,
    videoQuality: "balanced",
    videoCodec: "H265_10",
    videoBitrate: "2000000",
    videoFps: "24",
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
  const wssVideoFields = document.getElementById("wssVideoFields");
  const videoCodecEl = document.getElementById("videoCodec");
  const videoBitrateEl = document.getElementById("videoBitrate");
  const videoFpsEl = document.getElementById("videoFps");
  const audioEncoderEl = document.getElementById("audioEncoder");
  const audioBitrateEl = document.getElementById("audioBitrate");
  const audioQualityEl = document.getElementById("audioQuality");
  const inputMoveHzEl = document.getElementById("inputMoveHz");
  const gameModeButton = document.getElementById("gameModeButton");
  const GAME_MODE_SHORTCUT = "Ctrl+Alt+L";

  let ws = null;
  let videoTransport = "wss";
  let webrtcSignalPort = null;
  let webrtcPc = null;
  let webrtcSignalSocket = null;
  let webrtcVideoEl = null;
  let webrtcDrawHandle = null;
  let webrtcRemoteDescriptionSet = false;
  let webrtcPendingLocalCandidates = [];
  let webrtcPendingRemoteCandidates = [];
  let webrtcVideoActive = false;
  let webrtcConnectPromise = null;
  let webrtcConfirmTimer = null;
  let webrtcLastMediaTime = 0;
  let webrtcLastMediaAdvanceAt = 0;
  let webrtcDisconnectTimer = null;
  let webrtcIceTimeoutTimer = null;
  let webrtcEndOfCandidatesTimer = null;
  let webrtcSentServerIceCandidate = false;
  let webrtcAnswerSent = false;
  let webrtcEarlyTrickleActive = false;
  let webrtcUdpFailureReason = "";
  let webrtcUdpAbandoned = false;
  let webrtcIceState = "new";
  let webrtcSession = null;
  let webrtcConnectGeneration = 0;
  let serverWebRtcIceServers = null;
  let stunPreflightResult = "";
  let stunPreflightDetail = "";
  let stunPreflightPromise = null;
  let stunPreflightGeneration = 0;
  let webrtcLocalIceStats = { host: 0, localHost: 0, srflx: 0, relay: 0 };
  const WEBRTC_FRAME_CONFIRM_MS = 1500;
  const STUN_PREFLIGHT_TIMEOUT_MS = 6000;
  const WEBRTC_ICE_TIMEOUT_MS = 45000;
  const WEBRTC_ICE_GATHER_TIMEOUT_MS = 12000;
  const WEBRTC_ICE_EOC_DELAY_MS = 2500;
  const WEBRTC_STALL_MS = 3000;
  const WEBRTC_DISCONNECT_GRACE_MS = 4000;
  const REMOTE_WEBRTC_DISCONNECT_GRACE_MS = 30000;
  const REMOTE_ICE_ANSWER_DEADLINE_MS = 30000;
  const REMOTE_ICE_TRICKLE_TIMEOUT_MS = 30000;
  const relayOnlyDiagnostic =
    new URL(location.href).searchParams.get("relayOnly") === "1";
  let webrtcGatheredCandidateLines = [];
  let webrtcForceRelayOnly = false;
  let webrtcRelayReconnectAttempted = false;
  let webrtcConnectScheduled = false;
  let webrtcTrickleTimer = null;
  let webrtcTrickleDeadline = 0;
  let webrtcStatsTimer = null;
  let webrtcMediaVerified = false;
  let webrtcInboundPackets = 0;
  let webrtcInboundBytes = 0;
  let webrtcPreviousInboundPackets = 0;
  let webrtcRtpGrowthStreak = 0;
  let webrtcRtpProgressAt = 0;
  let webrtcSelectedPairSummary = "";
  let webrtcBlackFrameStreak = 0;
  let webrtcLastGoodVideoLuminance = 0;
  let webrtcBlackRecoverAt = 0;
  let webrtcBlackRecoverPackets = 0;
  let webrtcBlackDetectCanvas = null;
  let webrtcBlackDetectCtx = null;
  const WEBRTC_BLACK_LUMINANCE_THRESHOLD = 0.03;
  const WEBRTC_BLACK_RECOVER_FRAMES = 90;
  const WEBRTC_BLACK_RECOVER_COOLDOWN_MS = 12000;
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
  let inputStreamWidth = canvas.width;
  let inputStreamHeight = canvas.height;
  let connectionState = "idle";
  let pendingSettings = false;
  let applyingTransport = false;
  let appliedSettings = null;
  let appliedVideoTransportKey = "";
  let applyTransportTimer = null;
  let activeTransport = null;
  const TRANSPORT_APPLY_FIELDS = [
    "audioEncoder",
    "audioBitrate",
    "audioQuality",
    "inputMoveHz",
  ];
  const WSS_VIDEO_FIELDS = ["videoQuality", "videoCodec", "videoBitrate", "videoFps"];
  const UDP_VIDEO_FIELDS = ["videoCodec", "videoBitrate", "videoFps"];

  function transportApplyFields() {
    if (videoTransport === "udp") {
      return [...UDP_VIDEO_FIELDS, ...TRANSPORT_APPLY_FIELDS];
    }
    return [...WSS_VIDEO_FIELDS, ...TRANSPORT_APPLY_FIELDS];
  }

  function settingsForTransportMode(settings) {
    const payload = { settingsVersion: settings.settingsVersion };
    for (const field of transportApplyFields()) {
      payload[field] = settings[field];
    }
    return payload;
  }

  function updateTransportPanelVisibility() {
    const udp = videoTransport === "udp";
    if (wssVideoFields) wssVideoFields.hidden = udp;
  }
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
  let gameModeEscapeArmedAt = 0;
  let gameModeEscapeForwardUp = false;
  const GAME_MODE_ESCAPE_EXIT_MS = 800;
  const STREAM_STALL_MS = 8000;
  const activeAudioSources = new Set();
  let availableGames = [];
  /** Temporary transport-menu labels (game id → suffix after title). */
  const GAME_MENU_STATUS = {
    aoe2: "Not Working",
  };
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
      videoFps: videoFpsEl ? videoFpsEl.value : "24",
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
    if (videoFpsEl && settings.videoFps) {
      videoFpsEl.value = String(settings.videoFps);
    }
    audioEncoderEl.value = settings.audioEncoder;
    audioBitrateEl.value = settings.audioBitrate;
    audioQualityEl.value = settings.audioQuality;
    inputMoveHzEl.value = settings.inputMoveHz;
    moveInterval = 1000 / Number(settings.inputMoveHz || 60);
  }

  function videoTransportKey(settings) {
    if (!settings) return "";
    return [
      settings.videoQuality || "",
      settings.videoCodec || "",
      settings.videoBitrate || "",
      settings.videoFps || "",
    ].join("|");
  }

  function transportSettingsSnapshot(settings) {
    const snapshot = {};
    for (const field of transportApplyFields()) {
      snapshot[field] = settings[field];
    }
    return snapshot;
  }

  function transportSettingsChanged(previous, next) {
    return transportApplyFields().some((field) => previous[field] !== next[field]);
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
      videoFps: String(active.videoFps || streamFps),
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
    const settings = await browserCompatibleSettings(
      settingsForTransportMode(currentSettingsFromUi())
    );
    const next = transportSettingsSnapshot(settings);
    if (!transportSettingsChanged(appliedSettings, next)) return;

    applyingTransport = true;
    pendingSettings = false;
    pendingNotice.textContent = "Applying settings…";
    pendingNotice.classList.add("visible");
    connectionState = "streaming";
    updateTransportStatus();

    ws.send(JSON.stringify({
      type: "reconfigure",
      settings,
    }));

    resetVideoDecoder();
    resetAudioPlayback();
    void ensureDecoders();
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
    if (videoFpsEl) {
      for (const option of videoFpsEl.options) {
        option.disabled = available.videoFps && !available.videoFps.includes(Number(option.value));
      }
    }
    for (const option of audioEncoderEl.options) {
      option.disabled = !available.audioEncoder.includes(option.value);
      option.title = unavailableAudio[option.value] || "";
    }
    updateTransportPanelVisibility();
  }

  function transportControlElements() {
    const elements = [
      audioEncoderEl,
      audioBitrateEl,
      audioQualityEl,
      inputMoveHzEl,
    ];
    if (videoTransport === "udp") {
      if (videoFpsEl) elements.unshift(videoFpsEl);
      elements.unshift(videoBitrateEl);
      elements.unshift(videoCodecEl);
    } else {
      elements.unshift(videoQualityEl, videoCodecEl, videoBitrateEl, videoFpsEl);
    }
    return elements.filter(Boolean);
  }

  function updateTransportControlsEnabled() {
    const editable = clientRole === "controller";
    for (const el of transportControlElements()) {
      el.disabled = !editable;
    }
  }

  function updateTransportStatus(extraLines = []) {
    const settings = currentSettingsFromUi();
    const statsSeconds = Math.max((performance.now() - streamStatsStartedAt) / 1000, 0.001);
    const encodedVideoKbps = (videoBytes * 8) / statsSeconds / 1000;
    const lines = [
      "RA2 Ultra transport",
      `connection: ${connectionState}`,
      `requested: ${settings.videoQuality}/${settings.videoCodec}@${settings.videoBitrate}bps/${settings.videoFps || streamFps}fps ${settings.audioEncoder}@${settings.audioBitrate}bps/${settings.audioQuality}Hz input=${settings.inputMoveHz}Hz`,
    ];
    if (videoTransport === "udp") {
      if (stunPreflightResult === "checking") {
        lines.push("STUN: checking (browser NAT test)…");
      } else if (stunPreflightResult === "ok") {
        lines.push(`STUN: OK · ${stunPreflightDetail || "reflexive candidate (srflx)"}`);
      } else if (stunPreflightResult === "blocked") {
        lines.push(`STUN test: blocked · ${stunPreflightDetail || "no srflx yet"} (WebRTC still attempts UDP)`);
      } else if (stunPreflightResult === "unsupported") {
        lines.push("STUN: unavailable · browser lacks WebRTC");
      }
      if (webrtcVideoActive && webrtcMediaVerified) {
        lines.push("udp video: WebRTC verified");
        if (webrtcSelectedPairSummary) {
          lines.push(`webrtc path: ${webrtcSelectedPairSummary}`);
        }
        lines.push(
          `webrtc rtp: ${webrtcInboundPackets} pkts · ${(webrtcInboundBytes / 1024).toFixed(1)} KB`,
        );
        lines.push(`wss video rx: ${videoMessages} (should stop increasing)`);
      } else if (webrtcVideoActive) {
        lines.push("udp video: WebRTC (switching…)");        
      } else if (webrtcUdpFailureReason) {
        lines.push(`udp video: failed · ${webrtcUdpFailureReason}`);
      } else if (webrtcPc && webrtcIceState && webrtcIceState !== "new") {
        if (webrtcIceState === "connected" || webrtcIceState === "completed") {
          lines.push(`udp video: ICE ${webrtcIceState} — awaiting RTP…`);
          if (webrtcInboundPackets > 0) {
            lines.push(`webrtc rtp: ${webrtcInboundPackets} pkts (negotiated, not confirmed)`);
          }
        } else {
          lines.push(`udp video: ICE ${webrtcIceState}`);
        }
        lines.push(localIceStatusLine());
      }
    }
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
      ...extraLines,
    );
    transportStatus.textContent = lines.join("\n");
  }

  function setStatus(text) {
    const message = text || "";
    const duringConnect =
      connectionState === "idle" ||
      connectionState === "connecting" ||
      connectionState === "reconnecting";
    const overlayContext =
      gamePicker.classList.contains("visible") || watchPanel.classList.contains("visible");
    if (duringConnect && overlayContext) {
      if (overlayHint) {
        overlayHint.textContent = message;
        overlayHint.hidden = !message;
      } else if (overlayConnectButton) {
        overlayConnectButton.textContent = message || "Click to choose a game";
      } else if (overlayStatus) {
        overlayStatus.textContent = message;
      }
      if (overlay) overlay.classList.remove("hidden");
      return;
    }
    setSessionStatus(message);
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
    if (overlay) {
      overlay.classList.add("hidden");
      overlay.classList.remove("picker-open");
    }
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
    updateTransportControlsEnabled();
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

  function gameMenuButtonLabel(game) {
    const base = game.title || game.id;
    const status = GAME_MENU_STATUS[game.id];
    return status ? `${base} — ${status}` : base;
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
      btn.textContent = gameMenuButtonLabel(game);
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
    // Always offer the game picker on connect. Spectator mode is explicit
    // (Watch stream) unless selectGame is rejected server-side. Picking a game
    // triggers server-side controller takeover after IP/session changes.
    watchPanel.classList.remove("visible");
    showGamePicker(games, currentGameSession);
    if (controllerActive && controllerStreaming && clientRole !== "controller") {
      const title =
        currentGameSession && currentGameSession.title
          ? currentGameSession.title
          : "the active session";
      setStatus(
        `Another player is streaming ${title}. Select a game to take control, or use Watch stream.`,
      );
    }
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
    const startSettings = await browserCompatibleSettings(
      settingsForTransportMode(settings)
    );
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

  function webrtcSignalUrl() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    // Prefer same-origin signaling (/webrtc-signal on 6081/6082) so remote play
    // does not require forwarding extra TCP ports beyond the play page.
    if (location.protocol === "https:" || location.protocol === "http:") {
      return `${proto}//${location.host}/webrtc-signal`;
    }
    const port = webrtcSignalPort || (location.port === "6082" ? "6084" : "6083");
    return `${proto}//${location.hostname}:${port}/`;
  }

  function ensureWebRtcVideoEl() {
    if (webrtcVideoEl) return webrtcVideoEl;
    webrtcVideoEl = document.createElement("video");
    webrtcVideoEl.playsInline = true;
    webrtcVideoEl.autoplay = true;
    webrtcVideoEl.muted = true;
    webrtcVideoEl.hidden = true;
    document.body.appendChild(webrtcVideoEl);
    return webrtcVideoEl;
  }

  function resetWebRtcLocalIceStats() {
    webrtcLocalIceStats = { host: 0, localHost: 0, srflx: 0, relay: 0 };
  }

  function noteWebRtcLocalIceCandidateLine(line) {
    if (!line) return;
    if (/\btyp srflx\b/.test(line)) {
      webrtcLocalIceStats.srflx += 1;
      return;
    }
    if (/\btyp relay\b/.test(line)) {
      webrtcLocalIceStats.relay += 1;
      return;
    }
    if (/\btyp host\b/.test(line)) {
      if (/\.local\b/.test(line)) webrtcLocalIceStats.localHost += 1;
      else webrtcLocalIceStats.host += 1;
    }
  }

  function localIceStatusLine() {
    const stats = webrtcLocalIceStats;
    if (stats.srflx > 0) {
      return `ICE local: srflx=${stats.srflx} host=${stats.host} relay=${stats.relay}`;
    }
    if (stats.relay > 0) {
      return `ICE local: relay=${stats.relay} host=${stats.host}`;
    }
    if (stats.localHost > 0 || stats.host > 0) {
      return `ICE local: srflx=0 host=${stats.host} mdns=${stats.localHost}`;
    }
    return "ICE local: gathering…";
  }

  function runStunPreflight(force = false) {
    if (stunPreflightPromise && !force) return stunPreflightPromise;
    if (
      !force &&
      (stunPreflightResult === "ok" ||
        stunPreflightResult === "blocked" ||
        stunPreflightResult === "unsupported")
    ) {
      return Promise.resolve(stunPreflightResult === "ok");
    }
    if (!force && isRemotePlayPage() && hasConfiguredTurnServers()) {
      stunPreflightResult = "ok";
      stunPreflightDetail = "skipped on remote (TURN from turn-ice.json)";
      updateTransportStatus();
      return Promise.resolve(true);
    }
    if (!window.RTCPeerConnection) {
      stunPreflightResult = "unsupported";
      stunPreflightDetail = "browser lacks WebRTC";
      updateTransportStatus();
      return Promise.resolve(false);
    }
    stunPreflightResult = "checking";
    stunPreflightDetail = "";
    updateTransportStatus();
    const generation = ++stunPreflightGeneration;
    stunPreflightPromise = new Promise((resolve) => {
      let settled = false;
      let sawSrflx = false;
      let sawRelay = false;
      let sawLocalOnly = false;
      let pc = null;
      let timer = null;

      const finish = (ok, detail) => {
        if (settled || generation !== stunPreflightGeneration) return;
        settled = true;
        if (timer) window.clearTimeout(timer);
        if (pc) {
          pc.onicecandidate = null;
          pc.onicegatheringstatechange = null;
          pc.close();
          pc = null;
        }
        stunPreflightResult = ok ? "ok" : "blocked";
        stunPreflightDetail = detail || (ok ? "reflexive candidate (srflx)" : "no srflx");
        console.info("[ultra-play] stun preflight", stunPreflightResult, stunPreflightDetail, {
          sawSrflx,
          sawRelay,
          sawLocalOnly,
        });
        updateTransportStatus();
        resolve(ok);
      };

      const noteCandidate = (line) => {
        if (!line) return;
        if (/\btyp srflx\b/.test(line)) sawSrflx = true;
        if (/\btyp relay\b/.test(line)) sawRelay = true;
        if (/\btyp host\b/.test(line) && /\.local\b/.test(line)) sawLocalOnly = true;
      };

      const preflightLooksOk = () => sawSrflx || sawRelay;

      const maybeFinishFromGathering = (reason) => {
        if (!pc || pc.iceGatheringState !== "complete") return;
        if (preflightLooksOk()) {
          finish(true, sawRelay ? "relay candidate" : "reflexive candidate (srflx)");
          return;
        }
        finish(false, sawLocalOnly ? "only .local host candidates" : reason || "no srflx");
      };

      timer = window.setTimeout(() => {
        if (preflightLooksOk()) {
          finish(true, sawRelay ? "relay candidate" : "reflexive candidate (srflx)");
          return;
        }
        if (pc && pc.iceGatheringState === "complete") {
          maybeFinishFromGathering("timed out after gathering complete");
          return;
        }
        finish(
          false,
          sawLocalOnly ? "only .local host candidates" : "timed out waiting for STUN",
        );
      }, STUN_PREFLIGHT_TIMEOUT_MS);

      try {
        pc = createWebRtcPeerConnection();
      } catch (error) {
        finish(false, webRtcErrorDetail(error, "WebRTC unavailable"));
        return;
      }

      pc.onicecandidate = (event) => {
        if (!event.candidate) {
          maybeFinishFromGathering("ICE gathering finished");
          return;
        }
        noteCandidate(event.candidate.candidate || "");
      };
      pc.onicegatheringstatechange = () => {
        maybeFinishFromGathering("ICE gathering finished");
      };

      try {
        pc.addTransceiver("video", { direction: "recvonly" });
      } catch (error) {
        finish(false, webRtcErrorDetail(error, "WebRTC transceiver blocked"));
        return;
      }

      pc.createOffer()
        .then((offer) => pc.setLocalDescription(offer))
        .then(() => {
          if (pc.iceGatheringState === "complete") {
            maybeFinishFromGathering("ICE already complete");
          }
        })
        .catch((error) => {
          const detail = error && error.message ? error.message : "offer failed";
          finish(false, detail);
        });
    });
    return stunPreflightPromise;
  }

  const summarizeSdpIce = Ice.summarizeSdpIce;

  async function refreshWebRtcMediaStats(pc) {
    if (!pc) return false;
    const stats = await pc.getStats();
    let pair = null;
    for (const report of stats.values()) {
      if (report.type === "transport" && report.selectedCandidatePairId) {
        pair = stats.get(report.selectedCandidatePairId);
        break;
      }
    }
    let inbound = null;
    for (const report of stats.values()) {
      if (report.type === "inbound-rtp" && report.kind === "video") {
        inbound = report;
        break;
      }
    }
    if (pair) {
      const local = stats.get(pair.localCandidateId);
      const remote = stats.get(pair.remoteCandidateId);
      const localType = local?.candidateType || "?";
      const protocol = local?.protocol || "?";
      const remoteType = remote?.candidateType || "?";
      webrtcSelectedPairSummary = `${localType}/${protocol} → ${remoteType}`;
    }
    const packets = Number(inbound?.packetsReceived || 0);
    const framesDecoded = Number(inbound?.framesDecoded || 0);
    const framesReceived = Number(inbound?.framesReceived || 0);
    const rtp = Ice.isRtpSustained(
      webrtcPreviousInboundPackets,
      packets,
      webrtcRtpGrowthStreak,
      { minStreak: isRemotePlayPage() ? 2 : 1, minPackets: isRemotePlayPage() ? 12 : 6 },
    );
    webrtcRtpGrowthStreak = rtp.growthStreak;
    if (packets > webrtcPreviousInboundPackets) {
      webrtcRtpProgressAt = performance.now();
      if (webrtcVideoActive && webrtcDisconnectTimer) {
        clearWebRtcDisconnectTimer();
      }
    }
    webrtcPreviousInboundPackets = packets;
    webrtcInboundPackets = packets;
    webrtcInboundBytes = Number(inbound?.bytesReceived || 0);
    const verified = Ice.isUdpMediaVerified({
      isRemote: isRemotePlayPage(),
      framesDecoded,
      framesReceived,
      packets,
      rtpSustained: rtp.sustained,
    });
    if (verified) webrtcMediaVerified = true;
    return verified;
  }

  async function logSelectedPair(pc) {
    if (!pc) return;
    await refreshWebRtcMediaStats(pc);
    const stats = await pc.getStats();
    let pair = null;
    for (const report of stats.values()) {
      if (report.type === "transport" && report.selectedCandidatePairId) {
        pair = stats.get(report.selectedCandidatePairId);
        break;
      }
    }
    if (!pair) return;
    const local = stats.get(pair.localCandidateId);
    const remote = stats.get(pair.remoteCandidateId);
    let inbound = null;
    for (const report of stats.values()) {
      if (report.type === "inbound-rtp" && report.kind === "video") {
        inbound = report;
        break;
      }
    }
    console.info("[ultra-play] selected pair", {
      state: pair.state,
      nominated: pair.nominated,
      rtt: pair.currentRoundTripTime,
      localType: local?.candidateType,
      localProtocol: local?.protocol,
      localRelayProtocol: local?.relayProtocol,
      remoteType: remote?.candidateType,
      remoteProtocol: remote?.protocol,
      packetsReceived: inbound?.packetsReceived,
      bytesReceived: inbound?.bytesReceived,
      framesDecoded: inbound?.framesDecoded,
    });
    void tryConfirmWebRtcVideo();
  }

  function clearWebRtcStatsTimer() {
    if (webrtcStatsTimer) {
      window.clearInterval(webrtcStatsTimer);
      webrtcStatsTimer = null;
    }
  }

  function attachWebRtcPeerDiagnostics(pc) {
    if (!pc) return;
    clearWebRtcStatsTimer();
    pc.addEventListener("icecandidateerror", (event) => {
      const detail = `${event.errorText || "unknown"} (code ${event.errorCode}) ${event.url || ""}`;
      console.warn("[ultra-play] icecandidateerror", {
        url: event.url,
        errorCode: event.errorCode,
        errorText: event.errorText,
        address: event.address,
        port: event.port,
      });
      if (isRemotePlayPage() && /^(turn|turns):/i.test(String(event.url || ""))) {
        webrtcUdpFailureReason = detail;
      }
    });
    webrtcStatsTimer = window.setInterval(() => {
      logSelectedPair(pc).catch(() => {});
      if (webrtcVideoActive && webrtcPc) {
        void refreshWebRtcMediaStats(webrtcPc).then((ok) => {
          if (!ok && webrtcVideoActive) {
            const rtpGrowing =
              webrtcRtpProgressAt > 0 &&
              performance.now() - webrtcRtpProgressAt <
                Ice.stallGraceMs(isRemotePlayPage(), 3000, 6000);
            if (
              !rtpGrowing &&
              webrtcRtpProgressAt > 0 &&
              performance.now() - webrtcRtpProgressAt >
                Ice.stallGraceMs(isRemotePlayPage(), 8000, 15000)
            ) {
              fallbackFromWebRtcVideo("UDP RTP stalled — using browser stream fallback");
            }
          }
        });
      }
    }, 2000);
    if (relayOnlyDiagnostic) {
      console.info("[ultra-play] relay-only diagnostic mode (?relayOnly=1)");
    }
  }

  const isTurnIceEntry = Ice.isTurnIceEntry;

  function normalizeIceServers(servers) {
    const out = [];
    for (const entry of servers || []) {
      if (!entry || !entry.urls) continue;
      const urls = Array.isArray(entry.urls) ? entry.urls : [entry.urls];
      for (const url of urls) {
        const u = String(url || "").trim();
        if (!u) continue;
        const normalized = { urls: u };
        if (entry.username) normalized.username = entry.username;
        if (entry.credential) {
          normalized.credential = entry.credential;
          normalized.credentialType = "password";
        }
        out.push(normalized);
      }
    }
    return out;
  }

  async function refreshTurnIceServersFromServer() {
    try {
      const response = await fetch("/turn-ice.json", { cache: "no-store" });
      if (!response.ok) return false;
      const data = await response.json();
      if (Array.isArray(data.iceServers) && data.iceServers.length) {
        applyWebRtcIceServers(data.iceServers);
        return true;
      }
    } catch (error) {
      console.warn("[ultra-play] turn-ice.json fetch failed", error);
    }
    return false;
  }

  function isLanPlayPage() {
    return Ice.isLanHostname(location.hostname);
  }

  function isRemotePlayPage() {
    return Ice.isRemotePlayPage(location.hostname);
  }

  function rewriteTurnUrlsForLan(servers) {
    return Ice.rewriteTurnUrlsForLan(servers, location.hostname);
  }

  function orderIceServersForRemote(servers) {
    return Ice.orderIceServersForRemote(servers, location.hostname);
  }

  function applyWebRtcIceServers(servers) {
    if (!Array.isArray(servers) || !servers.length) return;
    const incoming = normalizeIceServers(
      orderIceServersForRemote(rewriteTurnUrlsForLan(servers)),
    );
    const incomingTurn = incoming.filter((e) => isTurnIceEntry(e));
    if (isRemotePlayPage() && !incomingTurn.length) {
      console.warn("[ultra-play] ignoring signaling ICE without TURN credentials on remote");
      return;
    }
    serverWebRtcIceServers = incoming;
    const turnCount = serverWebRtcIceServers.filter((e) => isTurnIceEntry(e)).length;
    console.info("[ultra-play] ICE servers", {
      total: serverWebRtcIceServers.length,
      turn: turnCount,
      turnWithCreds: turnCount,
      firstUrl: serverWebRtcIceServers[0]?.urls || "",
    });
  }

  function turnIceServers() {
    return (serverWebRtcIceServers || []).filter((e) => isTurnIceEntry(e));
  }

  function webrtcIceServerPresets() {
    const defaults = [
      { urls: "stun:stun.l.google.com:19302" },
      { urls: "stun:stun1.l.google.com:19302" },
      { urls: "stun:stun.cloudflare.com:3478" },
    ];
    const turn = turnIceServers();
    const combined =
      serverWebRtcIceServers && serverWebRtcIceServers.length
        ? serverWebRtcIceServers
        : defaults;
    if (turn.length) {
      // STUN + TURN together (not TURN-only) — relay-only is ?relayOnly=1 diagnostic only.
      return [combined, turn, defaults, []];
    }
    return [combined, defaults, [{ urls: "stun:stun.l.google.com:19302" }], []];
  }

  function webrtcIceServers() {
    const servers = webrtcIceServerPresets()[0];
    if (shouldUseRelayIcePolicy()) {
      const turnOnly = Ice.iceServersForRelayPlay(servers);
      if (turnOnly.length) return turnOnly;
    }
    return servers;
  }

  function hasConfiguredTurnServers() {
    const servers = serverWebRtcIceServers || webrtcIceServerPresets()[0];
    return servers.some((entry) => isTurnIceEntry(entry));
  }

  function shouldUseRelayIcePolicy() {
    return Ice.shouldUseRelayIcePolicy({
      relayOnlyDiagnostic,
      webrtcForceRelayOnly,
      preferRelayOnRemote: false,
      hasTurnServers: hasConfiguredTurnServers(),
    });
  }

  function fallbackReasonAllowsRelayRetry(reason) {
    return Ice.fallbackReasonAllowsRelayRetry(reason);
  }

  function remoteIceTrickleInProgress() {
    return Boolean(
      isRemotePlayPage() &&
        (webrtcEarlyTrickleActive || webrtcTrickleTimer || (webrtcAnswerSent && !webrtcSentServerIceCandidate)),
    );
  }

  function remotePlayIceServers() {
    const ordered = orderIceServersForRemote(serverWebRtcIceServers || [], location.hostname);
    const turn = Ice.turnServersForRemotePlay(ordered);
    if (turn.length) return turn;
    const all = serverWebRtcIceServers || [];
    return all.length ? all : webrtcIceServerPresets()[0];
  }

  function createWebRtcPeerConnection(options = {}) {
    const relayOnly = shouldUseRelayIcePolicy();
    if (relayOnly) {
      const iceServers = webrtcIceServers().filter((entry) => entry.username && entry.credential);
      if (!iceServers.length) {
        throw new Error("TURN servers with credentials required for remote relay ICE");
      }
      console.info("[ultra-play] RTCPeerConnection relay-only", {
        iceCount: iceServers.length,
        urls: iceServers.map((entry) => entry.urls),
      });
      return new RTCPeerConnection({
        iceServers,
        iceTransportPolicy: "relay",
        bundlePolicy: "max-bundle",
        ...options,
      });
    }
    if (isRemotePlayPage()) {
      const iceServers = remotePlayIceServers();
      const turnEntries = iceServers.filter((entry) => isTurnIceEntry(entry));
      if (!turnEntries.length) {
        throw new Error("TURN servers not loaded — turn-ice.json missing credentials");
      }
      console.info("[ultra-play] RTCPeerConnection remote TURN relay", {
        iceCount: iceServers.length,
        turnCount: turnEntries.length,
        urls: turnEntries.map((entry) => entry.urls),
      });
      return new RTCPeerConnection({
        iceServers,
        iceTransportPolicy: "relay",
        bundlePolicy: "max-bundle",
        ...options,
      });
    }
    const presets = webrtcIceServerPresets();
    let lastError = null;
    for (let presetIndex = 0; presetIndex < presets.length; presetIndex += 1) {
      const iceServers = presets[presetIndex];
      try {
        const pc = new RTCPeerConnection({
          iceServers,
          iceTransportPolicy: shouldUseRelayIcePolicy() ? "relay" : "all",
          bundlePolicy: "max-bundle",
          ...options,
        });
        const turnEntries = iceServers.filter((e) => isTurnIceEntry(e));
        console.info("[ultra-play] RTCPeerConnection", {
          presetIndex,
          iceCount: iceServers.length,
          turnCount: turnEntries.length,
          turnWithCreds: turnEntries.filter((e) => e.username && e.credential).length,
          relayOnly: shouldUseRelayIcePolicy(),
          remotePlay: isRemotePlayPage(),
        });
        return pc;
      } catch (error) {
        lastError = error;
        console.warn("[ultra-play] RTCPeerConnection preset failed", presetIndex, error);
      }
    }
    throw lastError || new Error("RTCPeerConnection unavailable");
  }

  function webRtcErrorDetail(error, fallback) {
    if (!error) return fallback;
    const message = error.message ? String(error.message) : String(error);
    return message || fallback;
  }

  function waitForLocalIceGathering(pc, timeoutMs = WEBRTC_ICE_GATHER_TIMEOUT_MS) {
    if (!pc || pc.iceGatheringState === "complete") {
      return Promise.resolve();
    }
    return new Promise((resolve) => {
      let settled = false;
      const finish = () => {
        if (settled) return;
        settled = true;
        pc.removeEventListener("icegatheringstatechange", onGathering);
        window.clearTimeout(timer);
        resolve();
      };
      const onGathering = () => {
        if (pc.iceGatheringState === "complete") finish();
      };
      pc.addEventListener("icegatheringstatechange", onGathering);
      const timer = window.setTimeout(finish, timeoutMs);
    });
  }

  const sdpHasUsableLocalIce = Ice.sdpHasUsableLocalIce;
  const sanitizeAnswerSdpForServer = Ice.sanitizeAnswerSdpForServer;
  const replaceMdnsWithIpInSdp = Ice.replaceMdnsWithIpInSdp;
  const localCandidateLinesFromSdp = Ice.localCandidateLinesFromSdp;

  function normalizeStatsCandidateLine(line, report) {
    return Ice.normalizeStatsCandidateLine(line, report);
  }

  async function discoverClientLanIp(pc) {
    const ips = [];
    const stats = await pc.getStats();
    for (const report of stats.values()) {
      if (report.type !== "local-candidate") continue;
      for (const key of ["address", "ipAddress", "ip", "relatedAddress"]) {
        const value = report[key];
        if (value && /^\d+\.\d+\.\d+\.\d+$/.test(value) && !value.startsWith("127.")) {
          ips.push(value);
        }
      }
    }
    for (const line of webrtcGatheredCandidateLines) {
      const fromLine = Ice.extractLanIpFromGatheredLines([line]);
      if (fromLine) ips.push(fromLine);
    }
    const lan = ips.find((ip) => ip.startsWith("192.168.") || ip.startsWith("10."));
    return lan || ips[0] || "";
  }

  async function finalizeAnswerSdpForServer(pc) {
    let sdp = pc.localDescription?.sdp || "";
    if (!sdpHasUsableLocalIce(sdp)) {
      sdp = Ice.embedCandidateLinesInSdp(sdp, webrtcGatheredCandidateLines);
    }
    if (!sdpHasUsableLocalIce(sdp)) {
      const hostIp = await discoverClientLanIp(pc);
      if (hostIp) {
        sdp = replaceMdnsWithIpInSdp(sdp, hostIp);
        await pc.setLocalDescription({ type: "answer", sdp });
        console.info("[ultra-play] rewrote mDNS answer to LAN IP", hostIp);
      }
    }
    if (!sdpHasUsableLocalIce(sdp)) {
      const injected = await injectLocalIceFromStats(pc);
      if (sdpHasUsableLocalIce(injected.sdp)) {
        sdp = injected.sdp;
        if (sdp !== pc.localDescription?.sdp) {
          await pc.setLocalDescription({ type: "answer", sdp });
        }
      }
    }
    if (
      !Ice.hasUsableIce({
        sdp,
        gatheredLines: webrtcGatheredCandidateLines,
      })
    ) {
      throw new Error("no reachable ICE candidate for server (mDNS-only browser)");
    }
    if (!sdpHasUsableLocalIce(sdp)) {
      sdp = Ice.embedCandidateLinesInSdp(sdp, webrtcGatheredCandidateLines);
      await pc.setLocalDescription({ type: "answer", sdp });
    }
    return sanitizeAnswerSdpForServer(sdp);
  }

  async function extractUsableCandidatesFromStats(pc) {
    if (!pc) return [];
    const stats = await pc.getStats();
    const out = [];
    const seen = new Set();
    for (const report of stats.values()) {
      if (report.type !== "local-candidate") continue;
      const typ = report.candidateType;
      if (typ !== "host" && typ !== "srflx" && typ !== "relay") continue;
      let line = report.candidate || "";
      line = normalizeStatsCandidateLine(line, report);
      if (!line) continue;
      if (/\btyp host\b/.test(line) && /\.local\b/.test(line)) continue;
      const key = line.trim();
      if (seen.has(key)) continue;
      seen.add(key);
      out.push(key);
    }
    return out;
  }

  async function injectLocalIceFromStats(pc) {
    const candidates = await extractUsableCandidatesFromStats(pc);
    if (!candidates.length) return { sdp: pc.localDescription?.sdp || "", candidates: [] };
    let sdp = pc.localDescription?.sdp || "";
    const hostLine = candidates.find((line) => /\btyp host\b/.test(line));
    const hostIp = hostLine ? hostLine.split(/\s+/)[4] : "";
    if (hostIp && /\.local\b/.test(sdp)) {
      sdp = replaceMdnsWithIpInSdp(sdp, hostIp);
    }
    sdp = sanitizeAnswerSdpForServer(sdp);
    if (sdp !== pc.localDescription?.sdp) {
      await pc.setLocalDescription({ type: "answer", sdp });
    }
    console.info("[ultra-play] injected ICE from getStats", {
      count: candidates.length,
      hostIp: hostIp || null,
    });
    return { sdp, candidates };
  }

  function hasUsableLocalIceNow(pc) {
    return Ice.hasUsableIce({
      sdp: pc?.localDescription?.sdp || "",
      gatheredLines: webrtcGatheredCandidateLines,
    });
  }

  async function mergeStatCandidatesIntoGathered(pc) {
    const statCandidates = await extractUsableCandidatesFromStats(pc);
    for (const line of statCandidates) {
      if (!webrtcGatheredCandidateLines.includes(line)) {
        webrtcGatheredCandidateLines.push(line);
      }
    }
    return statCandidates;
  }

  function hasRelayIceNow(pc) {
    return (
      Ice.sdpHasRelayIce(pc?.localDescription?.sdp || "") ||
      Ice.gatheredLinesHaveRelay(webrtcGatheredCandidateLines)
    );
  }

  async function waitForRemoteRelayCandidate(pc, timeoutMs = 20000) {
    if (hasRelayIceNow(pc)) return true;
    setSessionStatus("UDP video: allocating TURN relay…");
    const gotRelay = await waitForRelayInSdp(pc, timeoutMs);
    if (gotRelay || hasRelayIceNow(pc)) return true;
    const deadline = performance.now() + timeoutMs;
    while (performance.now() < deadline) {
      await mergeStatCandidatesIntoGathered(pc);
      if (hasRelayIceNow(pc)) return true;
      await new Promise((resolve) => window.setTimeout(resolve, 400));
    }
    return hasRelayIceNow(pc);
  }

  function waitForUsableLocalIce(pc, timeoutMs = 20000) {
    const check = () => hasUsableLocalIceNow(pc);
    if (check()) return Promise.resolve(true);
    return new Promise((resolve) => {
      let settled = false;
      const finish = (ok) => {
        if (settled) return;
        settled = true;
        pc.removeEventListener("icecandidate", onIce);
        pc.removeEventListener("icegatheringstatechange", onGather);
        window.clearTimeout(timer);
        resolve(ok);
      };
      const onIce = (event) => {
        if (event?.candidate?.candidate) {
          webrtcGatheredCandidateLines.push(event.candidate.candidate);
        }
        if (check()) finish(true);
        else if (pc.iceGatheringState === "complete") finish(check());
      };
      const onGather = () => {
        if (pc.iceGatheringState === "complete") finish(check());
      };
      pc.addEventListener("icecandidate", onIce);
      pc.addEventListener("icegatheringstatechange", onGather);
      const timer = window.setTimeout(() => finish(check()), timeoutMs);
    });
  }

  function waitForRelayInSdp(pc, timeoutMs = 25000) {
    const checkRelay = () => hasRelayIceNow(pc);
    if (checkRelay()) return Promise.resolve(true);
    return new Promise((resolve) => {
      let settled = false;
      const finish = (ok) => {
        if (settled) return;
        settled = true;
        pc.removeEventListener("icecandidate", onIce);
        pc.removeEventListener("icegatheringstatechange", onGather);
        window.clearTimeout(timer);
        resolve(ok);
      };
      const onIce = (event) => {
        if (event?.candidate?.candidate) {
          webrtcGatheredCandidateLines.push(event.candidate.candidate);
        }
        if (checkRelay()) finish(true);
        else if (pc.iceGatheringState === "complete") finish(checkRelay());
      };
      const onGather = () => {
        if (pc.iceGatheringState === "complete") finish(checkRelay());
      };
      pc.addEventListener("icecandidate", onIce);
      pc.addEventListener("icegatheringstatechange", onGather);
      const timer = window.setTimeout(() => finish(checkRelay()), timeoutMs);
    });
  }

  function signalingSocketActive() {
    return Boolean(webrtcSignalSocket && webrtcSignalSocket.readyState === WebSocket.OPEN);
  }

  function signalingSocketBusy() {
    return Boolean(
      webrtcSignalSocket &&
        (webrtcSignalSocket.readyState === WebSocket.CONNECTING ||
          webrtcSignalSocket.readyState === WebSocket.OPEN),
    );
  }

  async function closeWebRtcSignalingSocket() {
    const sock = webrtcSignalSocket;
    if (!sock) return;
    webrtcSignalSocket = null;
    sock.onopen = null;
    sock.onmessage = null;
    sock.onerror = null;
    sock.onclose = null;
    if (sock.readyState === WebSocket.CLOSED) return;
    await new Promise((resolve) => {
      sock.addEventListener("close", resolve, { once: true });
      sock.close();
    });
  }

  async function gatherIceBeforeRemoteAnswer(pc) {
    const deadlineMs = REMOTE_ICE_ANSWER_DEADLINE_MS;
    setSessionStatus("UDP video: gathering ICE for answer…");
    if (isRemotePlayPage() && hasConfiguredTurnServers()) {
      const gotRelay = await waitForRemoteRelayCandidate(pc, deadlineMs);
      if (!gotRelay) {
        console.warn("[ultra-play] no TURN relay after", deadlineMs, "ms gather");
      }
    } else if (shouldUseRelayIcePolicy()) {
      await waitForRelayInSdp(pc, deadlineMs);
    }
    if (!hasUsableLocalIceNow(pc)) {
      await waitForUsableLocalIce(pc, deadlineMs);
    }
    await mergeStatCandidatesIntoGathered(pc);
    await waitForLocalIceGathering(pc, 3000);
  }

  async function answerSdpForRemote(pc) {
    await mergeStatCandidatesIntoGathered(pc);
    let sdp = Ice.buildFastAnswerSdp(pc.localDescription?.sdp || "", webrtcGatheredCandidateLines);
    if (Ice.hasUsableIce({ sdp, gatheredLines: webrtcGatheredCandidateLines })) {
      try {
        sdp = await finalizeAnswerSdpForServer(pc);
      } catch (error) {
        console.warn("[ultra-play] remote answer finalize", error);
        sdp = sanitizeAnswerSdpForServer(
          Ice.embedCandidateLinesInSdp(pc.localDescription?.sdp || sdp, webrtcGatheredCandidateLines),
        );
      }
    } else {
      console.warn("[ultra-play] remote answer without usable ICE yet — trickle will follow");
    }
    return sdp;
  }

  async function buildWebRtcAnswerSdp(pc, options = {}) {
    const earlyTrickle = options.earlyTrickle !== false;
    const answer = await pc.createAnswer({
      offerToReceiveVideo: true,
      offerToReceiveAudio: false,
    });
    await pc.setLocalDescription(answer);
    setSessionStatus("UDP video: gathering ICE (waiting for STUN/TURN)…");
    updateTransportStatus();

    if (earlyTrickle) {
      if (isRemotePlayPage()) {
        await gatherIceBeforeRemoteAnswer(pc);
        const sdp = await answerSdpForRemote(pc);
        console.info("[ultra-play] answer ICE (remote)", summarizeSdpIce(sdp));
        return sdp;
      }
      let sdp = "";
      try {
        sdp = await finalizeAnswerSdpForServer(pc);
      } catch (error) {
        sdp = sanitizeAnswerSdpForServer(pc.localDescription?.sdp || "");
        if (!hasUsableLocalIceNow(pc)) {
          console.warn("[ultra-play] LAN early answer without usable ICE yet — trickle will follow", error);
        }
      }
      console.info("[ultra-play] answer ICE (early trickle)", summarizeSdpIce(sdp));
      return sdp;
    }

    const gatherMs = hasConfiguredTurnServers() ? 20000 : WEBRTC_ICE_GATHER_TIMEOUT_MS;
    await waitForUsableLocalIce(pc, gatherMs);
    if (
      (webrtcForceRelayOnly || relayOnlyDiagnostic) &&
      hasConfiguredTurnServers() &&
      !hasRelayIceNow(pc)
    ) {
      setSessionStatus("UDP video: waiting for TURN relay…");
      await waitForRelayInSdp(pc, gatherMs);
    }
    await waitForLocalIceGathering(pc, 3000);
    const sdp = await finalizeAnswerSdpForServer(pc);
    const hasSrflx = /\btyp srflx\b/.test(sdp);
    const hasRelay = /\btyp relay\b/.test(sdp);
    const iceSummary = summarizeSdpIce(sdp);
    console.info("[ultra-play] answer ICE", {
      ...iceSummary,
      hasSrflx,
      hasRelay,
      sdpBytes: new TextEncoder().encode(sdp || "").length,
      relayOnly: relayOnlyDiagnostic,
    });
    if (hasSrflx) {
      setSessionStatus("UDP video: STUN candidate ready in answer");
    } else if (hasRelay) {
      setSessionStatus("UDP video: TURN relay candidate ready in answer");
    } else if (hasConfiguredTurnServers()) {
      setSessionStatus("UDP video: waiting for TURN relay in answer…");
    } else {
      setSessionStatus("UDP video: no srflx in answer — STUN blocked (TURN not configured)");
    }
    return sdp;
  }

  function sendTrickleCandidateLine(candidate, sent, meta = {}) {
    if (!candidate || sent.has(candidate)) return;
    if (!shouldSendLocalIceCandidateLine(candidate)) return;
    if (
      sendLocalIcePayload({
        type: "ice",
        candidate,
        sdpMid: meta.sdpMid ?? "0",
        sdpMLineIndex: meta.sdpMLineIndex ?? 0,
      })
    ) {
      sent.add(candidate);
    }
  }

  async function waitForUsefulIceTrickle(pc, timeoutMs = 20000) {
    const sent = new Set();
    const deadline = performance.now() + timeoutMs;
    while (performance.now() < deadline) {
      if (webrtcSentServerIceCandidate) return true;
      for (const candidate of webrtcGatheredCandidateLines) {
        sendTrickleCandidateLine(candidate, sent);
      }
      const statCandidates = await extractUsableCandidatesFromStats(pc);
      for (const candidate of statCandidates) {
        sendTrickleCandidateLine(candidate, sent);
      }
      for (const payload of webrtcPendingLocalCandidates.splice(0)) {
        sendTrickleCandidateLine(payload.candidate, sent);
      }
      if (webrtcSentServerIceCandidate) return true;
      await new Promise((resolve) => window.setTimeout(resolve, 400));
    }
    return webrtcSentServerIceCandidate;
  }

  function flushUsableIceTrickle(pc, sent = new Set()) {
    const sdp = pc?.localDescription?.sdp || "";
    for (const candidate of localCandidateLinesFromSdp(sdp)) {
      sendTrickleCandidateLine(candidate, sent);
    }
    for (const candidate of webrtcGatheredCandidateLines) {
      sendTrickleCandidateLine(candidate, sent);
    }
    return sent;
  }

  async function flushUsableIceTrickleFromStats(pc, sent = new Set()) {
    const statCandidates = await extractUsableCandidatesFromStats(pc);
    for (const candidate of statCandidates) {
      sendTrickleCandidateLine(candidate, sent);
    }
    for (const payload of webrtcPendingLocalCandidates.splice(0)) {
      sendTrickleCandidateLine(payload.candidate, sent);
    }
    return sent;
  }

  function clearWebRtcTrickleTimer() {
    if (webrtcTrickleTimer) {
      window.clearInterval(webrtcTrickleTimer);
      webrtcTrickleTimer = null;
    }
    webrtcTrickleDeadline = 0;
  }

  function startWebRtcTrickleLoop(pc) {
    clearWebRtcTrickleTimer();
    webrtcTrickleDeadline = performance.now() + REMOTE_ICE_TRICKLE_TIMEOUT_MS;
    const tick = async () => {
      if (!webrtcSignalSocket || webrtcSignalSocket.readyState !== WebSocket.OPEN || !pc) {
        clearWebRtcTrickleTimer();
        return;
      }
      flushUsableIceTrickle(pc);
      await flushUsableIceTrickleFromStats(pc);
      if (webrtcSentServerIceCandidate) {
        webrtcEarlyTrickleActive = false;
        sendWebRtcEndOfCandidates(0);
        clearWebRtcTrickleTimer();
        setSessionStatus("UDP video: TURN relay sent — negotiating…");
        updateTransportStatus();
        return;
      }
      if (performance.now() > webrtcTrickleDeadline) {
        clearWebRtcTrickleTimer();
        const detail = webrtcUdpFailureReason || "no TURN relay candidate (VPN may block UDP 62011)";
        fallbackFromWebRtcVideo(`UDP signaling failed: ${detail}`, {
          allowRelayRetry: Ice.fallbackReasonAllowsRelayRetry(detail),
        });
      }
    };
    void tick();
    webrtcTrickleTimer = window.setInterval(() => {
      void tick();
    }, 1500);
  }

  async function completeIceTrickleAfterAnswer(pc, initialAnswerSdp) {
    let sent = flushUsableIceTrickle(pc);
    await flushUsableIceTrickleFromStats(pc, sent);
    if (!webrtcSentServerIceCandidate) {
      setSessionStatus("UDP video: sending TURN relay candidates…");
      await waitForUsefulIceTrickle(pc, isRemotePlayPage() ? REMOTE_ICE_TRICKLE_TIMEOUT_MS : 12000);
    }
    if (!webrtcSentServerIceCandidate && isRemotePlayPage() && hasConfiguredTurnServers()) {
      await waitForRelayInSdp(pc, 12000);
      sent = flushUsableIceTrickle(pc);
      await flushUsableIceTrickleFromStats(pc, sent);
      if (!webrtcSentServerIceCandidate) {
        await waitForUsefulIceTrickle(pc, 12000);
      }
    }
    const iceSummary = summarizeSdpIce(initialAnswerSdp);
    console.info("[ultra-play] trickle ICE complete (sync)", {
      ...iceSummary,
      sent: sent.size,
      usefulSent: webrtcSentServerIceCandidate,
      remotePlay: isRemotePlayPage(),
    });
    if (!Ice.shouldSendEndOfCandidates(webrtcSentServerIceCandidate)) {
      throw new Error("no usable ICE candidate reached server (trickle timeout)");
    }
    sendWebRtcEndOfCandidates(0);
    updateTransportStatus();
  }

  function clearWebRtcEndOfCandidatesTimer() {
    if (webrtcEndOfCandidatesTimer) {
      window.clearTimeout(webrtcEndOfCandidatesTimer);
      webrtcEndOfCandidatesTimer = null;
    }
  }

  function shouldSendLocalIceCandidateLine(line) {
    if (!line) return false;
    // Remote GStreamer/libnice cannot resolve browser mDNS hostnames (*.local).
    if (/\btyp host\b/.test(line) && /\.local\b/.test(line)) return false;
    return true;
  }

  function noteUsefulLocalIceCandidateLine(line) {
    if (!line) return;
    if (/\btyp srflx\b/.test(line) || /\btyp relay\b/.test(line)) {
      webrtcSentServerIceCandidate = true;
      return;
    }
    if (/\btyp host\b/.test(line) && !/\.local\b/.test(line)) {
      webrtcSentServerIceCandidate = true;
    }
  }

  function sendLocalIcePayload(payload) {
    noteWebRtcLocalIceCandidateLine(payload.candidate);
    updateTransportStatus();
    if (!shouldSendLocalIceCandidateLine(payload.candidate)) return false;
    noteUsefulLocalIceCandidateLine(payload.candidate);
    if (/\btyp srflx\b/.test(payload.candidate)) {
      setSessionStatus("UDP video: STUN candidate ready, finishing ICE…");
    }
    if (!webrtcSignalSocket || webrtcSignalSocket.readyState !== WebSocket.OPEN) {
      return false;
    }
    if (!webrtcRemoteDescriptionSet || !webrtcAnswerSent) {
      webrtcPendingLocalCandidates.push(payload);
      return true;
    }
    console.info("[ultra-play] client ICE → server", String(payload.candidate || "").slice(0, 96));
    webrtcSignalSocket.send(JSON.stringify(payload));
    return true;
  }

  function sendWebRtcEndOfCandidates(mlineIndex = 0) {
    clearWebRtcEndOfCandidatesTimer();
    if (!Ice.shouldSendEndOfCandidates(webrtcSentServerIceCandidate)) {
      console.warn("[ultra-play] refusing empty end-of-candidates");
      return;
    }
    if (!webrtcSignalSocket || webrtcSignalSocket.readyState !== WebSocket.OPEN) return;
    webrtcSignalSocket.send(
      JSON.stringify({ type: "ice", candidate: "", sdpMLineIndex: mlineIndex, complete: true }),
    );
  }

  function scheduleWebRtcEndOfCandidates(mlineIndex = 0) {
    if (
      !Ice.shouldScheduleTrickleEndOfCandidates({
        earlyTrickleActive: webrtcEarlyTrickleActive,
        answerSent: webrtcAnswerSent,
      })
    ) {
      return;
    }
    clearWebRtcEndOfCandidatesTimer();
    const delay = webrtcSentServerIceCandidate ? 0 : WEBRTC_ICE_EOC_DELAY_MS;
    webrtcEndOfCandidatesTimer = window.setTimeout(() => {
      webrtcEndOfCandidatesTimer = null;
      sendWebRtcEndOfCandidates(mlineIndex);
      if (!webrtcSentServerIceCandidate) {
        setSessionStatus("UDP video: no srflx yet — trying TCP ICE fallback…");
        updateTransportStatus();
      }
    }, delay);
  }

  function clearWebRtcIceTimeoutTimer() {
    if (webrtcIceTimeoutTimer) {
      window.clearTimeout(webrtcIceTimeoutTimer);
      webrtcIceTimeoutTimer = null;
    }
  }

  function clearWebRtcConfirmTimer() {
    if (webrtcConfirmTimer) {
      window.clearTimeout(webrtcConfirmTimer);
      webrtcConfirmTimer = null;
    }
  }

  function clearWebRtcDisconnectTimer() {
    if (webrtcDisconnectTimer) {
      window.clearTimeout(webrtcDisconnectTimer);
      webrtcDisconnectTimer = null;
    }
  }

  function sendVideoPath(path) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify({ type: "videoPath", path }));
  }

  function resetWebRtcBlackFrameRecovery() {
    webrtcBlackFrameStreak = 0;
    webrtcLastGoodVideoLuminance = 0;
    webrtcBlackRecoverAt = 0;
    webrtcBlackRecoverPackets = 0;
  }

  function sampleWebRtcVideoLuminance(videoEl) {
    if (!videoEl?.videoWidth || !videoEl?.videoHeight) return 0;
    if (!webrtcBlackDetectCanvas) {
      webrtcBlackDetectCanvas = document.createElement("canvas");
      webrtcBlackDetectCanvas.width = 16;
      webrtcBlackDetectCanvas.height = 16;
      webrtcBlackDetectCtx = webrtcBlackDetectCanvas.getContext("2d", {
        willReadFrequently: true,
      });
    }
    if (!webrtcBlackDetectCtx) return 0;
    webrtcBlackDetectCtx.drawImage(videoEl, 0, 0, 16, 16);
    const data = webrtcBlackDetectCtx.getImageData(0, 0, 16, 16).data;
    let sum = 0;
    for (let i = 0; i < data.length; i += 4) {
      sum += data[i] + data[i + 1] + data[i + 2];
    }
    return sum / (data.length / 4) / 3 / 255;
  }

  function maybeRecoverWebRtcBlackVideo(videoEl) {
    if (!webrtcVideoActive || !webrtcMediaVerified || webrtcUdpAbandoned) return;
    const lum = sampleWebRtcVideoLuminance(videoEl);
    if (lum >= 0.08) {
      webrtcLastGoodVideoLuminance = lum;
      webrtcBlackFrameStreak = 0;
      return;
    }
    if (webrtcLastGoodVideoLuminance < 0.08) return;
    if (lum >= WEBRTC_BLACK_LUMINANCE_THRESHOLD) {
      webrtcBlackFrameStreak = 0;
      return;
    }
    webrtcBlackFrameStreak += 1;
    if (webrtcBlackFrameStreak < WEBRTC_BLACK_RECOVER_FRAMES) return;
    const now = performance.now();
    if (now - webrtcBlackRecoverAt < WEBRTC_BLACK_RECOVER_COOLDOWN_MS) return;
    if (webrtcInboundPackets <= webrtcBlackRecoverPackets) return;
    webrtcBlackRecoverAt = now;
    webrtcBlackRecoverPackets = webrtcInboundPackets;
    webrtcBlackFrameStreak = 0;
    console.warn("[ultra-play] WebRTC video went black with live RTP — reconnecting");
    setSessionStatus("UDP video black — recovering…");
    stopWebRtcVideo();
    void connectWebRtcVideo();
  }

  function confirmWebRtcVideo() {
    if (webrtcVideoActive) return;
    if (!webrtcMediaVerified) return;
    clearWebRtcConfirmTimer();
    if (webrtcSession?.failTimer) {
      window.clearTimeout(webrtcSession.failTimer);
      webrtcSession.failTimer = null;
    }
    webrtcVideoActive = true;
    webrtcUdpFailureReason = "";
    resetWebRtcBlackFrameRecovery();
    sendVideoPath("webrtc");
    connectionState = "decoding";
    setSessionStatus("Video: UDP/WebRTC verified");
  }

  function fallbackFromWebRtcVideo(reason, options = {}) {
    if (
      Ice.shouldAttemptRemoteRelayRetry({
        allowRelayRetry: options.allowRelayRetry,
        reason,
        relayReconnectAttempted: webrtcRelayReconnectAttempted,
        relayOnlyDiagnostic,
        isRemotePlayPage: isRemotePlayPage(),
        hasTurnServers: hasConfiguredTurnServers(),
      })
    ) {
      webrtcRelayReconnectAttempted = true;
      console.warn("[ultra-play] remote UDP failed — relay-only retry", reason);
      setSessionStatus("UDP video: retrying via TURN relay…");
      clearWebRtcConfirmTimer();
      clearWebRtcDisconnectTimer();
      clearWebRtcIceTimeoutTimer();
      clearWebRtcEndOfCandidatesTimer();
      clearWebRtcTrickleTimer();
      clearWebRtcStatsTimer();
      webrtcSession = null;
      webrtcVideoActive = false;
      webrtcMediaVerified = false;
      webrtcConnectPromise = null;
      webrtcForceRelayOnly = true;
      void (async () => {
        await closeWebRtcSignalingSocket();
        stopWebRtcVideo();
        try {
          await connectWebRtcVideo({ relayRetry: true });
        } finally {
          webrtcForceRelayOnly = false;
        }
      })();
      return;
    }
    webrtcUdpAbandoned = true;
    clearWebRtcConfirmTimer();
    clearWebRtcDisconnectTimer();
    clearWebRtcIceTimeoutTimer();
    clearWebRtcEndOfCandidatesTimer();
    clearWebRtcTrickleTimer();
    clearWebRtcStatsTimer();
    webrtcSession = null;
    if (reason) {
      webrtcUdpFailureReason = reason.replace(" — using browser stream fallback", "");
    } else if (!webrtcUdpFailureReason) {
      webrtcUdpFailureReason = "ICE negotiation failed";
    }
    const wasActive = webrtcVideoActive;
    webrtcVideoActive = false;
    webrtcMediaVerified = false;
    webrtcInboundPackets = 0;
    webrtcInboundBytes = 0;
    webrtcPreviousInboundPackets = 0;
    webrtcRtpGrowthStreak = 0;
    webrtcRtpProgressAt = 0;
    webrtcSelectedPairSummary = "";
    webrtcConnectPromise = null;
    webrtcLastMediaTime = 0;
    webrtcLastMediaAdvanceAt = 0;
    if (webrtcDrawHandle) {
      cancelAnimationFrame(webrtcDrawHandle);
      webrtcDrawHandle = null;
    }
    if (webrtcVideoEl) {
      webrtcVideoEl.srcObject = null;
    }
    if (webrtcPc) {
      webrtcPc.close();
      webrtcPc = null;
    }
    if (webrtcSignalSocket) {
      webrtcSignalSocket.onclose = null;
      webrtcSignalSocket.close();
      webrtcSignalSocket = null;
    }
    webrtcRemoteDescriptionSet = false;
    webrtcPendingLocalCandidates = [];
    webrtcPendingRemoteCandidates = [];
    webrtcSentServerIceCandidate = false;
    webrtcAnswerSent = false;
    webrtcEarlyTrickleActive = false;
    if (reason) {
      setSessionStatus(reason);
    }
    sendVideoPath("wss");
    resetVideoDecoder();
    void ensureDecoders();
    if (wasActive || reason) {
      recoverVideoPresentation({ forcePresent: true });
    }
    updateTransportStatus();
  }

  function stopWebRtcVideo(options = {}) {
    const preserveConnectPromise = options.preserveConnectPromise === true;
    clearWebRtcConfirmTimer();
    clearWebRtcDisconnectTimer();
    clearWebRtcIceTimeoutTimer();
    clearWebRtcEndOfCandidatesTimer();
    clearWebRtcTrickleTimer();
    clearWebRtcStatsTimer();
    webrtcIceState = "new";
    webrtcVideoActive = false;
    webrtcMediaVerified = false;
    webrtcInboundPackets = 0;
    webrtcInboundBytes = 0;
    webrtcPreviousInboundPackets = 0;
    webrtcRtpGrowthStreak = 0;
    webrtcRtpProgressAt = 0;
    webrtcSelectedPairSummary = "";
    resetWebRtcBlackFrameRecovery();
    if (!preserveConnectPromise) {
      webrtcConnectPromise = null;
    }
    webrtcLastMediaTime = 0;
    webrtcLastMediaAdvanceAt = 0;
    if (webrtcDrawHandle) {
      cancelAnimationFrame(webrtcDrawHandle);
      webrtcDrawHandle = null;
    }
    if (webrtcSignalSocket) {
      webrtcSignalSocket.onclose = null;
      webrtcSignalSocket.close();
      webrtcSignalSocket = null;
    }
    if (webrtcPc) {
      webrtcPc.close();
      webrtcPc = null;
    }
    webrtcRemoteDescriptionSet = false;
    webrtcPendingLocalCandidates = [];
    webrtcPendingRemoteCandidates = [];
    webrtcSentServerIceCandidate = false;
    webrtcAnswerSent = false;
    webrtcEarlyTrickleActive = false;
    webrtcSession = null;
    if (webrtcVideoEl) {
      webrtcVideoEl.srcObject = null;
    }
  }

  function scheduleWebRtcIceTimeout(onTimeout) {
    clearWebRtcIceTimeoutTimer();
    webrtcIceTimeoutTimer = window.setTimeout(() => {
      webrtcIceTimeoutTimer = null;
      if (webrtcVideoActive || !webrtcPc) return;
      const ice = webrtcPc.iceConnectionState;
      if (ice === "connected" || ice === "completed") return;
      onTimeout();
    }, WEBRTC_ICE_TIMEOUT_MS);
  }

  function tryConfirmWebRtcVideo() {
    if (webrtcVideoActive || !webrtcPc) return;
    const ice = webrtcPc.iceConnectionState;
    if (ice !== "connected" && ice !== "completed") return;
    void refreshWebRtcMediaStats(webrtcPc).then((verified) => {
      updateTransportStatus();
      if (verified) confirmWebRtcVideo();
    });
  }

  function noteWebRtcMediaProgress(videoEl) {
    const mediaTime = videoEl.currentTime;
    const rtpGrowing =
      webrtcRtpProgressAt > 0 &&
      performance.now() - webrtcRtpProgressAt <
        Ice.stallGraceMs(isRemotePlayPage(), 2000, 4000);
    if (mediaTime <= webrtcLastMediaTime + 0.0005) {
      if (
        webrtcVideoActive &&
        webrtcLastMediaAdvanceAt &&
        Ice.shouldFallbackForStall({
          lastProgressAt: webrtcLastMediaAdvanceAt,
          now: performance.now(),
          stallMs: Ice.stallGraceMs(isRemotePlayPage(), WEBRTC_STALL_MS, 12000),
          rtpGrowing,
        })
      ) {
        fallbackFromWebRtcVideo("UDP video stalled — using browser stream fallback");
      }
      return false;
    }
    webrtcLastMediaTime = mediaTime;
    webrtcLastMediaAdvanceAt = performance.now();
    if (!webrtcVideoActive) {
      tryConfirmWebRtcVideo();
    }
    return true;
  }

  function startWebRtcVideoDrawLoop() {
    const videoEl = ensureWebRtcVideoEl();
    webrtcLastMediaTime = videoEl.currentTime;
    webrtcLastMediaAdvanceAt = 0;
    const draw = () => {
      webrtcDrawHandle = requestAnimationFrame(draw);
      if (!videoEl.videoWidth || !videoEl.videoHeight) return;
      if (!noteWebRtcMediaProgress(videoEl)) {
        if (!webrtcVideoActive) return;
      }
      if (!webrtcVideoActive) return;
      // Keep mouse/input mapped to server stream size — do not retarget coords to WebRTC encode size.
      ctx.drawImage(videoEl, 0, 0, canvas.width, canvas.height);
      maybeRecoverWebRtcBlackVideo(videoEl);
      framesDecoded += 1;
      lastVideoFrameAt = performance.now();
      updateTransportStatus();
    };
    if (webrtcDrawHandle) cancelAnimationFrame(webrtcDrawHandle);
    webrtcDrawHandle = requestAnimationFrame(draw);
  }

  async function flushWebRtcRemoteCandidates() {
    if (!webrtcRemoteDescriptionSet || !webrtcPc) return;
    const queue = webrtcPendingRemoteCandidates.splice(0);
    for (const candidate of queue) {
      try {
        await webrtcPc.addIceCandidate(candidate);
      } catch (error) {
        console.warn("webrtc addIceCandidate", error);
      }
    }
  }

  let webrtcSignalChain = Promise.resolve();

  function enqueueWebRtcSignalMessage(raw) {
    webrtcSignalChain = webrtcSignalChain
      .then(() => handleWebRtcSignalMessage(raw))
      .catch((error) => {
        throw error;
      });
    return webrtcSignalChain;
  }

  function resetWebRtcPeerForRelayRetry() {
    if (webrtcPc) {
      webrtcPc.close();
      webrtcPc = null;
    }
    webrtcRemoteDescriptionSet = false;
    webrtcPendingLocalCandidates = [];
    webrtcPendingRemoteCandidates = [];
    webrtcSentServerIceCandidate = false;
    webrtcAnswerSent = false;
    webrtcEarlyTrickleActive = false;
    resetWebRtcLocalIceStats();
    webrtcGatheredCandidateLines = [];
  }

  async function applyWebRtcOfferMessage(data) {
    if (isRemotePlayPage()) {
      await refreshTurnIceServersFromServer();
      if (!hasConfiguredTurnServers()) {
        throw new Error("TURN servers unavailable (turn-ice.json)");
      }
    }
    if (!webrtcPc && webrtcSession && webrtcSession.setupPeerConnection) {
      await webrtcSession.setupPeerConnection();
    }
    if (!webrtcPc) {
      throw new Error("WebRTC peer connection unavailable");
    }
    await webrtcPc.setRemoteDescription({ type: "offer", sdp: data.sdp });
    webrtcRemoteDescriptionSet = true;
    await flushWebRtcRemoteCandidates();
    webrtcEarlyTrickleActive = true;
    let answerSdp;
    try {
      answerSdp = await buildWebRtcAnswerSdp(webrtcPc, { earlyTrickle: true });
    } catch (firstError) {
      if (!hasConfiguredTurnServers() || webrtcForceRelayOnly || relayOnlyDiagnostic) {
        throw firstError;
      }
      console.warn("[ultra-play] retrying offer with TURN relay-only ICE", firstError);
      const offerSdp = data.sdp;
      resetWebRtcPeerForRelayRetry();
      webrtcForceRelayOnly = true;
      if (webrtcSession?.setupPeerConnection) {
        await webrtcSession.setupPeerConnection();
      }
      if (!webrtcPc) throw firstError;
      try {
        await webrtcPc.setRemoteDescription({ type: "offer", sdp: offerSdp });
        webrtcRemoteDescriptionSet = true;
        await flushWebRtcRemoteCandidates();
        answerSdp = await buildWebRtcAnswerSdp(webrtcPc, { earlyTrickle: true });
      } finally {
        webrtcForceRelayOnly = false;
      }
    }
    if (!webrtcSignalSocket || webrtcSignalSocket.readyState !== WebSocket.OPEN) {
      throw new Error("UDP signaling socket closed before answer");
    }
    if (isRemotePlayPage() && hasConfiguredTurnServers() && !hasRelayIceNow(webrtcPc)) {
      throw new Error("no TURN relay candidate (check icecandidateerror in console)");
    }
    webrtcSignalSocket.send(JSON.stringify({ type: "answer", sdp: answerSdp }));
    webrtcAnswerSent = true;
    for (const payload of webrtcPendingLocalCandidates.splice(0)) {
      sendLocalIcePayload(payload);
    }
    console.info("[ultra-play] answer sent — trickling ICE", summarizeSdpIce(answerSdp));
    setSessionStatus("UDP video: answer sent, trickling ICE…");
    let sent = flushUsableIceTrickle(webrtcPc);
    await flushUsableIceTrickleFromStats(webrtcPc, sent);
    if (isRemotePlayPage()) {
      startWebRtcTrickleLoop(webrtcPc);
      return;
    }
    webrtcEarlyTrickleActive = false;
    await completeIceTrickleAfterAnswer(webrtcPc, answerSdp);
  }

  async function handleWebRtcSignalMessage(raw) {
    const data = JSON.parse(raw);
    if (data.type === "offer") {
      await applyWebRtcOfferMessage(data);
      return;
    }
    if (data.type === "ice") {
      if (!data.candidate) {
        if (!webrtcRemoteDescriptionSet || !webrtcPc) return;
        try {
          await webrtcPc.addIceCandidate(null);
        } catch (error) {
          console.warn("webrtc addIceCandidate end", error);
        }
        return;
      }
      const candidate = {
        candidate: data.candidate,
        sdpMid: data.sdpMid,
        sdpMLineIndex: data.sdpMLineIndex,
      };
      if (!webrtcRemoteDescriptionSet) {
        webrtcPendingRemoteCandidates.push(candidate);
        return;
      }
      try {
        await webrtcPc.addIceCandidate(candidate);
      } catch (error) {
        console.warn("webrtc addIceCandidate remote", error);
      }
      return;
    }
  }

  function connectWebRtcVideo(options = {}) {
    if (videoTransport !== "udp" || !window.RTCPeerConnection) {
      return Promise.resolve(false);
    }
    const relayRetry = options.relayRetry === true;
    if (!relayRetry && webrtcUdpAbandoned) {
      return Promise.resolve(false);
    }
    if (!relayRetry && (signalingSocketBusy() || webrtcConnectPromise)) {
      if (webrtcConnectPromise) return webrtcConnectPromise;
      return Promise.resolve(true);
    }
    if (webrtcConnectPromise) return webrtcConnectPromise;
    if (!relayRetry) {
      webrtcRelayReconnectAttempted = false;
    }
    const generation = ++webrtcConnectGeneration;
    webrtcConnectPromise = (async () => {
      await refreshTurnIceServersFromServer();
      if (isRemotePlayPage() && !hasConfiguredTurnServers()) {
        setSessionStatus("UDP video: loading TURN servers…");
        await refreshTurnIceServersFromServer();
      }
      if (isRemotePlayPage() && !hasConfiguredTurnServers()) {
        setSessionStatus("UDP video: TURN unavailable (turn-ice.json)");
        return false;
      }
      void runStunPreflight();
      if (isRemotePlayPage() && hasConfiguredTurnServers()) {
        console.info(
          "[ultra-play] remote play — ICE",
          shouldUseRelayIcePolicy() ? "relay (TURN via DDNS)" : "all",
        );
      }
      return new Promise((resolve) => {
      stopWebRtcVideo({ preserveConnectPromise: true });
      resetWebRtcLocalIceStats();
      webrtcGatheredCandidateLines = [];
      webrtcSentServerIceCandidate = false;
      webrtcAnswerSent = false;
      webrtcEarlyTrickleActive = false;
      webrtcUdpFailureReason = "";
      clearWebRtcEndOfCandidatesTimer();
      const videoEl = ensureWebRtcVideoEl();
      let settled = false;
      const finish = (ok) => {
        if (settled) return;
        settled = true;
        webrtcConnectPromise = null;
        resolve(ok);
      };
      const failTimer = window.setTimeout(() => {
        if (!webrtcVideoActive) {
          if (webrtcPc) {
            logSelectedPair(webrtcPc).catch(() => {});
          }
          const detail = webrtcLocalIceStats.relay
            ? "relay gathered but video never confirmed"
            : webrtcLocalIceStats.srflx
              ? "ICE never connected"
              : relayOnlyDiagnostic
                ? "relay-only: no TURN relay candidate (check icecandidateerror)"
                : "no srflx/relay ICE candidate from browser/network";
          fallbackFromWebRtcVideo(`UDP video timed out (${detail})`);
          finish(false);
        }
      }, WEBRTC_ICE_TIMEOUT_MS + 5000);

      async function setupPeerConnection() {
        if (webrtcPc) return;
        if (isRemotePlayPage()) {
          await refreshTurnIceServersFromServer();
          if (!hasConfiguredTurnServers()) {
            window.clearTimeout(failTimer);
            fallbackFromWebRtcVideo("TURN servers unavailable (turn-ice.json)", {
              allowRelayRetry: false,
            });
            finish(false);
            return;
          }
        }
        try {
          webrtcPc = createWebRtcPeerConnection();
          attachWebRtcPeerDiagnostics(webrtcPc);
        } catch (error) {
          window.clearTimeout(failTimer);
          fallbackFromWebRtcVideo(
            `WebRTC unavailable: ${webRtcErrorDetail(error, "browser blocked peer connection")}`,
            { allowRelayRetry: false },
          );
          finish(false);
          return;
        }
        webrtcPc.ontrack = (event) => {
          console.info("[ultra-play] ontrack", {
            kind: event.track?.kind,
            streams: event.streams?.length || 0,
          });
          const stream = event.streams[0] || new MediaStream([event.track]);
          videoEl.srcObject = stream;
          videoEl.play().catch((error) => console.warn("webrtc video play", error));
          startWebRtcVideoDrawLoop();
          setSessionStatus("UDP video track received — awaiting RTP…");
          finish(true);
        };
        webrtcPc.onconnectionstatechange = () => {
          const state = webrtcPc ? webrtcPc.connectionState : "";
          if (state === "connected") {
            clearWebRtcDisconnectTimer();
            tryConfirmWebRtcVideo();
            return;
          }
          if (state === "failed") {
            window.clearTimeout(failTimer);
            if (webrtcVideoActive) return;
            if (remoteIceTrickleInProgress()) {
              console.warn("[ultra-play] connection failed during remote trickle — waiting for TURN relay");
              return;
            }
            fallbackFromWebRtcVideo("WebRTC connection failed — using browser stream fallback");
            finish(false);
            return;
          }
          if (state === "disconnected" && webrtcVideoActive) {
            const ice = webrtcPc ? webrtcPc.iceConnectionState : "";
            if (ice === "connected" || ice === "completed") {
              return;
            }
            clearWebRtcDisconnectTimer();
            const graceMs = Ice.disconnectGraceMs(
              isRemotePlayPage(),
              WEBRTC_DISCONNECT_GRACE_MS,
              REMOTE_WEBRTC_DISCONNECT_GRACE_MS,
            );
            webrtcDisconnectTimer = window.setTimeout(() => {
              if (!webrtcPc || webrtcPc.connectionState !== "disconnected") return;
              const rtpRecent =
                webrtcRtpProgressAt > 0 &&
                performance.now() - webrtcRtpProgressAt <
                  Ice.stallGraceMs(isRemotePlayPage(), 5000, 15000);
              if (
                !Ice.shouldFallbackOnConnectionDisconnect({
                  videoActive: webrtcVideoActive,
                  iceConnectionState: webrtcPc.iceConnectionState,
                  rtpRecent,
                })
              ) {
                return;
              }
              fallbackFromWebRtcVideo("UDP video lost — using browser stream fallback");
              finish(false);
            }, graceMs);
          }
        };
        webrtcPc.oniceconnectionstatechange = () => {
          const iceState = webrtcPc ? webrtcPc.iceConnectionState : "";
          webrtcIceState = iceState || "new";
          updateTransportStatus();
          if (iceState === "checking") {
            if (!remoteIceTrickleInProgress()) {
              setSessionStatus("UDP video: ICE checking…");
              scheduleWebRtcIceTimeout(() => {
                window.clearTimeout(failTimer);
                fallbackFromWebRtcVideo("ICE checking timed out — using browser stream fallback");
                finish(false);
              });
            }
            return;
          }
          if (iceState === "connected" || iceState === "completed") {
            window.clearTimeout(failTimer);
            clearWebRtcIceTimeoutTimer();
            clearWebRtcDisconnectTimer();
            setSessionStatus("UDP video: ICE connected, starting stream…");
            clearWebRtcConfirmTimer();
            tryConfirmWebRtcVideo();
            webrtcConfirmTimer = window.setTimeout(tryConfirmWebRtcVideo, WEBRTC_FRAME_CONFIRM_MS);
            window.setTimeout(() => {
              if (!webrtcVideoActive && webrtcPc) {
                tryConfirmWebRtcVideo();
              }
            }, WEBRTC_FRAME_CONFIRM_MS + 500);
            return;
          }
          if (iceState === "failed") {
            window.clearTimeout(failTimer);
            if (webrtcVideoActive) {
              clearWebRtcDisconnectTimer();
              const graceMs = Ice.disconnectGraceMs(
                isRemotePlayPage(),
                WEBRTC_DISCONNECT_GRACE_MS,
                REMOTE_WEBRTC_DISCONNECT_GRACE_MS,
              );
              webrtcDisconnectTimer = window.setTimeout(() => {
                if (!webrtcPc || webrtcPc.iceConnectionState !== "failed") return;
                const rtpRecent =
                  webrtcRtpProgressAt > 0 &&
                  performance.now() - webrtcRtpProgressAt <
                    Ice.stallGraceMs(isRemotePlayPage(), 5000, 15000);
                if (rtpRecent) return;
                fallbackFromWebRtcVideo("UDP ICE lost — using browser stream fallback");
                finish(false);
              }, graceMs);
              return;
            }
            if (remoteIceTrickleInProgress()) {
              console.warn("[ultra-play] ICE failed during remote trickle — waiting for TURN relay");
              return;
            }
            const detail = webrtcLocalIceStats.relay
              ? "connectivity checks failed"
              : webrtcLocalIceStats.srflx
                ? "connectivity checks failed"
                : hasConfiguredTurnServers()
                  ? "no TURN relay candidate (check icecandidateerror)"
                  : "no srflx candidate — outbound STUN may be blocked";
            fallbackFromWebRtcVideo(`ICE failed (${detail})`);
            finish(false);
          }
        };
        webrtcPc.onicecandidate = (event) => {
          if (event.candidate?.candidate) {
            webrtcGatheredCandidateLines.push(event.candidate.candidate);
            sendLocalIcePayload({
              type: "ice",
              candidate: event.candidate.candidate,
              sdpMid: event.candidate.sdpMid,
              sdpMLineIndex: event.candidate.sdpMLineIndex,
            });
            return;
          }
          if (!webrtcSignalSocket || webrtcSignalSocket.readyState !== WebSocket.OPEN) {
            return;
          }
          scheduleWebRtcEndOfCandidates(event.candidate?.sdpMLineIndex ?? 0);
        };
      }

      webrtcSession = { finish, failTimer, videoEl, setupPeerConnection };

      const signalSocket = new WebSocket(webrtcSignalUrl());
      webrtcSignalSocket = signalSocket;
      signalSocket.onopen = () => {
        setSessionStatus("Connecting UDP video…");
      };
      signalSocket.onmessage = (event) => {
        if (generation !== webrtcConnectGeneration) return;
        enqueueWebRtcSignalMessage(event.data).catch((error) => {
          console.error("webrtc signal", error);
          const detail = error && error.message ? error.message : String(error);
          setSessionStatus(`UDP video signaling failed: ${detail}`);
          window.clearTimeout(failTimer);
          fallbackFromWebRtcVideo(`UDP signaling failed: ${detail}`, {
            allowRelayRetry: Ice.fallbackReasonAllowsRelayRetry(detail),
          });
          finish(false);
        });
      };
      signalSocket.onerror = () => {
        if (generation !== webrtcConnectGeneration) return;
        if (signalSocket !== webrtcSignalSocket) return;
        window.clearTimeout(failTimer);
        fallbackFromWebRtcVideo("UDP video signaling unavailable — using browser stream fallback", {
          allowRelayRetry: false,
        });
        finish(false);
      };
      signalSocket.onclose = (event) => {
        if (generation !== webrtcConnectGeneration) return;
        if (signalSocket !== webrtcSignalSocket) return;
        if (event && (event.code === 4001 || event.code === 4000)) return;
        if (webrtcVideoActive) return;
        window.clearTimeout(failTimer);
        if (connectionState === "streaming" || connectionState === "decoding") {
          const why = event && event.code === 4001 ? "another WebRTC tab is open" : "signaling socket closed";
          fallbackFromWebRtcVideo(`UDP signaling lost (${why})`, { allowRelayRetry: false });
        }
        finish(false);
      };
    });
    })();
    return webrtcConnectPromise;
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
    if (compatible.videoCodec) {
      compatible.videoCodec = await resolveActiveVideoDecoderCodec(compatible.videoCodec, {
        recordFallbacks: true,
      });
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

  async function applyStreamReady(msg) {
    if (msg.width && msg.height) {
      syncStreamDimensions(msg.width, msg.height);
    }
    if (msg.nativeWidth && msg.nativeHeight) {
      nativeWidth = msg.nativeWidth;
      nativeHeight = msg.nativeHeight;
    }
    let videoTransportChanged = false;
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
      const nextVideoKey = videoTransportKey(msg.active);
      videoTransportChanged = Boolean(nextVideoKey && nextVideoKey !== appliedVideoTransportKey);
      if (nextVideoKey) {
        appliedVideoTransportKey = nextVideoKey;
      }
    }
    resetVideoDecoder();
    resetAudioPlayback();
    await ensureDecoders();
    if (videoTransport === "udp" && !webrtcUdpAbandoned) {
      if (msg.reason === "reconfigure") {
        if (videoTransportChanged) {
          stopWebRtcVideo();
          void connectWebRtcVideo();
        }
        return;
      }
      if (msg.reason && msg.reason !== "start") {
        return;
      }
      if (webrtcConnectScheduled || signalingSocketBusy() || webrtcConnectPromise) return;
      webrtcConnectScheduled = true;
      window.setTimeout(() => {
        webrtcConnectScheduled = false;
        void connectWebRtcVideo();
      }, 500);
    }
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
      syncVirtualMouseFromGame();
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
    if (videoTransport === "udp" && webrtcVideoActive) return;
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
    inputStreamWidth = w;
    inputStreamHeight = h;
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
    gameSurface.style.setProperty("--stream-ar-w", String(w));
    gameSurface.style.setProperty("--stream-ar-h", String(h));
    syncVirtualMouseFromGame();
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

  function isEscapeKey(event) {
    return event.key === "Escape" || event.code === "Escape";
  }

  function resetGameModeEscapeArm() {
    gameModeEscapeArmedAt = 0;
    gameModeEscapeForwardUp = false;
  }

  function gameModeEscapeArmed(now = performance.now()) {
    return (
      gameModeEscapeArmedAt > 0
      && now - gameModeEscapeArmedAt <= GAME_MODE_ESCAPE_EXIT_MS
    );
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
      w: inputStreamWidth || streamWidth || canvas.width,
      h: inputStreamHeight || streamHeight || canvas.height,
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
    const rect = canvasContentRect();
    const { w, h } = streamGameSize();
    const scaleX = w / Math.max(1, rect.width);
    const scaleY = h / Math.max(1, rect.height);
    virtualGameX = clamp(virtualGameX + event.movementX * scaleX, 0, w - 1);
    virtualGameY = clamp(virtualGameY + event.movementY * scaleY, 0, h - 1);
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
    const { w, h } = streamGameSize();
    const maxX = Math.max(1, w - 1);
    const maxY = Math.max(1, h - 1);
    return {
      clientX: rect.left + (gameX / maxX) * rect.width,
      clientY: rect.top + (gameY / maxY) * rect.height,
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

    const local = gameCoordsToScreen(virtualGameX, virtualGameY);
    const remote = gameCoordsToScreen(remoteSentGameX, remoteSentGameY);

    placeCursorMarker(localCursor, local.clientX, local.clientY);
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
    resetGameModeEscapeArm();
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
    resetGameModeEscapeArm();
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
      event.stopPropagation();
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
    window.addEventListener("keydown", handleGameModeEscapeKeyDown, true);
    window.addEventListener("keyup", handleGameModeEscapeKeyUp, true);
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

  function handleGameModeEscapeKeyDown(event) {
    if (!isEscapeKey(event) || event.repeat) return;
    if (!isGameModeActive()) {
      resetGameModeEscapeArm();
      return;
    }

    const now = performance.now();
    if (gameModeEscapeArmed(now)) {
      resetGameModeEscapeArm();
      event.preventDefault();
      event.stopPropagation();
      void exitGameMode();
      return;
    }

    gameModeEscapeArmedAt = now;
    gameModeEscapeForwardUp = true;
    event.preventDefault();
    event.stopPropagation();
    if (isPointerLocked()) {
      document.exitPointerLock();
    }
    sendInput({ type: "keydown", key: "Escape" });
  }

  function handleGameModeEscapeKeyUp(event) {
    if (!isEscapeKey(event) || event.repeat) return;
    if (!isGameModeActive()) {
      resetGameModeEscapeArm();
      return;
    }

    event.preventDefault();
    event.stopPropagation();
    if (!gameModeEscapeForwardUp) return;
    gameModeEscapeForwardUp = false;
    sendInput({ type: "keyup", key: "Escape" });
  }

  function handleKeyDown(e) {
    if (e.repeat || isGameModeShortcut(e) || isEscapeKey(e)) return;
    if (pressedKeys.has(e.key)) {
      e.preventDefault();
      return;
    }
    pressedKeys.add(e.key);
    sendInput({ type: "keydown", key: e.key });
    e.preventDefault();
  }

  function handleKeyUp(e) {
    if (isGameModeShortcut(e) || isEscapeKey(e)) return;
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
    panelHeader.addEventListener("click", (event) => {
      event.stopPropagation();
      controlPanel.classList.toggle("collapsed");
      panelToggle.textContent = controlPanel.classList.contains("collapsed") ? "▼" : "▲";
    });
    panelHeader.addEventListener("dblclick", (event) => {
      event.preventDefault();
      event.stopPropagation();
    });
    controlPanel.addEventListener("dblclick", (event) => {
      event.preventDefault();
      event.stopPropagation();
    });
    for (const el of [
      videoQualityEl,
      videoCodecEl,
      videoBitrateEl,
      videoFpsEl,
      audioEncoderEl,
      audioBitrateEl,
      audioQualityEl,
      inputMoveHzEl,
    ]) {
      if (!el) continue;
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
    webrtcUdpAbandoned = false;
    webrtcUdpFailureReason = "";
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
          videoTransport = msg.videoTransport || "wss";
          webrtcSignalPort = msg.webrtcSignalPort || null;
          updateTransportPanelVisibility();
          if (videoTransport === "udp") {
            void refreshTurnIceServersFromServer().finally(() => runStunPreflight());
          } else if (Array.isArray(msg.webrtcIceServers) && msg.webrtcIceServers.length) {
            applyWebRtcIceServers(msg.webrtcIceServers);
          } else {
            stunPreflightResult = "";
            stunPreflightDetail = "";
            stunPreflightPromise = null;
          }
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
        if (videoTransport === "udp" && isRemotePlayPage()) {
          void refreshTurnIceServersFromServer();
        } else if (Array.isArray(msg.webrtcIceServers) && msg.webrtcIceServers.length) {
          applyWebRtcIceServers(msg.webrtcIceServers);
        }
        applySessionPresence(msg);
        updateSpectatorUi();
        updateTransportControlsEnabled();
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
          if (controlPanel) controlPanel.classList.add("collapsed");
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
      stopWebRtcVideo();
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
