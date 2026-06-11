(function () {
  const params = new URLSearchParams(window.location.search);
  const signalPort = params.get("signal") || "6083";
  const inputPort = params.get("input") || "6085";
  const host = window.location.hostname;
  const pageScheme = window.location.protocol === "https:" ? "wss" : "ws";
  const signalSchemes = params.get("signalScheme")
    ? [params.get("signalScheme")]
    : pageScheme === "wss"
      ? ["wss", "ws"]
      : ["ws", "wss"];
  const inputSchemes = params.get("inputScheme")
    ? [params.get("inputScheme")]
    : signalSchemes;

  const videoEl = document.getElementById("remoteVideo");
  const audioEl = document.getElementById("remoteAudio");
  const canvasEl = document.getElementById("remoteCanvas");
  const canvasCtx = canvasEl.getContext("2d");
  const statusEl = document.getElementById("status");
  const overlayEl = document.getElementById("overlay");
  const overlayStatusEl = document.getElementById("overlayStatus");
  const surfaceEl = document.getElementById("surface");
  const settingsButton = document.getElementById("settingsButton");
  const settingsPanel = document.getElementById("settingsPanel");
  const settingsClose = document.getElementById("settingsClose");
  const fitModeEl = document.getElementById("fitMode");
  const renderModeEl = document.getElementById("renderMode");
  const audioVolumeEl = document.getElementById("audioVolume");
  const showCursorEl = document.getElementById("showCursor");
  const showControlsEl = document.getElementById("showControls");
  const videoSmoothingEl = document.getElementById("videoSmoothing");
  const fullscreenButton = document.getElementById("fullscreenButton");
  const pointerLockButton = document.getElementById("pointerLockButton");
  const reconnectButton = document.getElementById("reconnectButton");
  const reloadButton = document.getElementById("reloadButton");

  let pc = null;
  let signalSocket = null;
  let inputSocket = null;
  let remoteDescriptionSet = false;
  let pendingRemoteCandidates = [];
  let pendingLocalCandidates = [];
  let inputCaptured = false;
  let activePointerId = null;
  let drawLoopStarted = false;
  let statsTimer = null;
  let lastDecodedFrameCount = 0;
  let frameStalls = 0;
  let presentedVideoFrames = 0;
  let lastPresentedVideoFrames = 0;
  let lastPresentedVideoFrameAt = 0;
  let paintStalls = 0;
  let noDecodedDimensionStats = 0;
  let autoReconnectAttempts = 0;
  let autoReconnectTimer = null;
  let videoFrameCallbackStarted = false;
  let iceCheckingStartedAt = 0;
  let lastAdvertisedMediaPort = "";
  let inputMoveSent = 0;
  let inputMoveDropped = 0;
  const INPUT_MOVE_HZ = Math.max(30, Math.min(250, Number(params.get("inputHz")) || 125));
  const INPUT_MOVE_INTERVAL_MS = 1000 / INPUT_MOVE_HZ;
  const AUTO_RECONNECT_ON_STALL = params.get("autoReconnect") !== "0";
  const settingsKey = "ra2RemotePlaySettings";
  const isSafari = /^((?!chrome|android|crios|fxios).)*safari/i.test(navigator.userAgent);
  const defaultSettings = {
    fitMode: "contain",
    renderMode: "canvas",
    audioVolume: 100,
    showCursor: false,
    showControls: true,
    videoSmoothing: true,
  };
  let settings = loadSettings();

  function loadSettings() {
    try {
      const saved = JSON.parse(window.localStorage.getItem(settingsKey) || "{}");
      return { ...defaultSettings, ...saved };
    } catch (error) {
      return { ...defaultSettings };
    }
  }

  function saveSettings() {
    window.localStorage.setItem(settingsKey, JSON.stringify(settings));
  }

  function updateSetting(key, value) {
    settings = { ...settings, [key]: value };
    saveSettings();
    applySettings();
  }

  function applySettings() {
    if (fitModeEl) {
      fitModeEl.value = settings.fitMode;
    }
    if (renderModeEl) {
      renderModeEl.value = settings.renderMode;
    }
    if (audioVolumeEl) {
      audioVolumeEl.value = String(settings.audioVolume);
    }
    if (showCursorEl) {
      showCursorEl.checked = Boolean(settings.showCursor);
    }
    if (showControlsEl) {
      showControlsEl.checked = Boolean(settings.showControls);
    }
    if (videoSmoothingEl) {
      videoSmoothingEl.checked = Boolean(settings.videoSmoothing);
    }
    if (audioEl) {
      audioEl.volume = Math.max(0, Math.min(1, Number(settings.audioVolume) / 100));
    }
    if (canvasEl) {
      canvasEl.style.cursor = settings.showCursor ? "crosshair" : "none";
    }
    document.body.classList.toggle("controls-hidden", !settings.showControls);
    document.body.classList.toggle("direct-video", settings.renderMode === "direct");
    applyVideoLayout();
  }

  function setStatus(text) {
    if (statusEl) {
      statusEl.textContent = text;
    }
    if (overlayStatusEl) {
      overlayStatusEl.textContent = text;
    }
    console.log("[remote]", text);
  }

  function reportDebug(message) {
    console.log("[remote-debug]", message);
    if (!inputSocket || inputSocket.readyState !== WebSocket.OPEN) {
      return;
    }
    inputSocket.send(JSON.stringify({ type: "debug", message }));
  }

  function startStatsReporter() {
    if (statsTimer) {
      return;
    }
    statsTimer = window.setInterval(() => {
      reportRuntimeStats().catch((error) => {
        reportDebug(`stats failed: ${error.message || error}`);
      });
    }, 5000);
  }

  function stopStatsReporter() {
    if (!statsTimer) {
      return;
    }
    window.clearInterval(statsTimer);
    statsTimer = null;
  }

  function getVideoFrameCallback() {
    if (!videoEl) {
      return null;
    }
    const requestVideoFrameCallback =
      videoEl.requestVideoFrameCallback || videoEl.webkitRequestVideoFrameCallback;
    if (typeof requestVideoFrameCallback !== "function") {
      return null;
    }
    return requestVideoFrameCallback.bind(videoEl);
  }

  function startVideoFrameMonitor() {
    if (videoFrameCallbackStarted) {
      return;
    }
    const requestVideoFrameCallback = getVideoFrameCallback();
    if (!requestVideoFrameCallback) {
      reportDebug("requestVideoFrameCallback unavailable; using WebRTC decode stats only");
      return;
    }
    videoFrameCallbackStarted = true;
    const onVideoFrame = (_now, metadata) => {
      presentedVideoFrames = metadata?.presentedFrames || presentedVideoFrames + 1;
      lastPresentedVideoFrameAt = performance.now();
      requestVideoFrameCallback(onVideoFrame);
    };
    requestVideoFrameCallback(onVideoFrame);
  }

  function browserSupportsHevc() {
    if (!window.RTCRtpReceiver || typeof RTCRtpReceiver.getCapabilities !== "function") {
      return false;
    }
    const caps = RTCRtpReceiver.getCapabilities("video");
    return (caps.codecs || []).some((codecInfo) => {
      const mime = (codecInfo.mimeType || "").toLowerCase();
      return mime.includes("h265") || mime.includes("hevc");
    });
  }

  function requestedCodec() {
    return (params.get("codec") || "H264").toUpperCase();
  }

  async function reportRuntimeStats() {
    if (!pc) {
      return;
    }
    let inboundBytes = 0;
    let framesDecoded = 0;
    let selectedTransport = "";
    let packetsLost = 0;
    let jitterMs = 0;
    const stats = await pc.getStats();
    stats.forEach((report) => {
      if (report.type === "candidate-pair" && report.selected) {
        selectedTransport = report.protocol || selectedTransport;
      }
      if (report.type === "transport" && report.selectedCandidatePairId) {
        const pair = stats.get(report.selectedCandidatePairId);
        if (pair) {
          selectedTransport = pair.protocol || selectedTransport;
        }
      }
      if (report.type !== "inbound-rtp") {
        return;
      }
      if (report.kind !== "video" && report.mediaType !== "video") {
        return;
      }
      inboundBytes += report.bytesReceived || 0;
      framesDecoded = report.framesDecoded || framesDecoded;
      packetsLost += report.packetsLost || 0;
      jitterMs = report.jitter != null ? Math.round(report.jitter * 1000) : jitterMs;
    });
    const decodedAdvanced = framesDecoded > lastDecodedFrameCount;
    const presentedAdvanced = presentedVideoFrames > lastPresentedVideoFrames;
    if (pc.connectionState === "connected" && framesDecoded === lastDecodedFrameCount) {
      frameStalls += 1;
    }
    if (
      pc.connectionState === "connected" &&
      inboundBytes > 0 &&
      videoEl.videoWidth === 0 &&
      videoEl.videoHeight === 0
    ) {
      noDecodedDimensionStats += 1;
      if (noDecodedDimensionStats >= 3) {
        scheduleAutoMediaReconnect("connected with RTP bytes but no decoded dimensions");
      }
    } else if (videoEl.videoWidth > 0 && videoEl.videoHeight > 0) {
      noDecodedDimensionStats = 0;
      autoReconnectAttempts = 0;
    }
    if (pc.connectionState === "connected" && decodedAdvanced && !presentedAdvanced && getVideoFrameCallback()) {
      paintStalls += 1;
      reportDebug(
        `video frame stalled: decoded=${framesDecoded} presented=${presentedVideoFrames} ready=${videoEl.readyState}`
      );
      if (paintStalls >= 2) {
        showResumeOverlay(
          "Video decode is advancing, but Safari stopped presenting frames to the page."
        );
        playRemoteMedia();
      }
    } else if (presentedAdvanced) {
      paintStalls = 0;
    }
    lastDecodedFrameCount = framesDecoded;
    lastPresentedVideoFrames = presentedVideoFrames;
    const summary = [
      `decoded=${framesDecoded}`,
      `presented=${presentedVideoFrames}`,
      `stalls=${frameStalls}`,
      `paintStalls=${paintStalls}`,
      `ice=${pc.iceConnectionState}`,
      `peer=${pc.connectionState}`,
      `transport=${selectedTransport || "unknown"}`,
      `lost=${packetsLost}`,
      `jitterMs=${jitterMs}`,
      `rx=${inboundBytes}`,
      `ready=${videoEl.readyState}`,
      `inputHz=${INPUT_MOVE_HZ}`,
      `moves=${inputMoveSent}`,
      `dropped=${inputMoveDropped}`,
    ].join(" ");
    reportDebug(`stats ${summary}`);
    if (pc.connectionState === "connected") {
      const transportLabel = selectedTransport ? ` · ${selectedTransport.toUpperCase()}` : "";
      setStatus(`connected · ${framesDecoded} frames · ice=${pc.iceConnectionState}${transportLabel}`);
    }
  }

  function hideOverlayWhenPlaying() {
    if (!overlayEl || !videoEl) {
      return;
    }
    if (videoEl.videoWidth > 0 && videoEl.videoHeight > 0) {
      overlayEl.classList.add("hidden");
    }
  }

  function dismissOverlay() {
    if (overlayEl) {
      overlayEl.classList.add("hidden");
    }
  }

  function novncFallbackUrl() {
    const novncLink = document.getElementById("novncLink");
    if (novncLink && novncLink.href) {
      return novncLink.href;
    }
    return "../vnc.html";
  }

  function buildIceFailureHint(state) {
    const host = window.location.hostname;
    const lines = [
      `WebRTC media ${state || "failed"}. Signaling may work while video ports are blocked.`,
      "",
      "Checklist:",
      `- Forward TCP 6081-6086 and UDP/TCP 62001-62040 to the NAS for remote WebRTC.`,
      `- Set WEBRTC_ICE_CANDIDATE_HOST=${host} on the NAS for DDNS play.`,
      `- Run: sh scripts/check-webrtc-ice-reachability.sh on the NAS.`,
      lastAdvertisedMediaPort
        ? `- Active media port from ICE: ${lastAdvertisedMediaPort} (must be reachable).`
        : "- Connect once, then re-run ICE reachability check for the active media port.",
      "",
      "Production play: use Moonlight over Tailscale (see docs/MOONLIGHT_EXPERIMENT.md).",
      `Admin fallback: ${novncFallbackUrl()}`,
    ];
    return lines.join("\n");
  }

  function noteRemoteCandidate(candidateLine) {
    if (!candidateLine || typeof candidateLine !== "string") {
      return;
    }
    const parts = candidateLine.trim().split(/\s+/);
    if (parts.length < 6) {
      return;
    }
    const typ = parts[7] || parts[0] || "";
    if (typ !== "host" && typ !== "srflx" && typ !== "relay" && parts[0] !== "candidate") {
      return;
    }
    const port = parts[5];
    if (port && /^\d+$/.test(port)) {
      lastAdvertisedMediaPort = port;
      reportDebug(`remote ICE candidate port=${port} typ=${typ || "unknown"}`);
    }
  }

  function showIceFailureOverlay(state) {
    showResumeOverlay(buildIceFailureHint(state));
  }

  function showResumeOverlay(message) {
    if (!overlayEl || !overlayStatusEl) {
      return;
    }
    overlayStatusEl.textContent = `${message}\n\nClick the remote surface to resume video/audio.`;
    overlayEl.classList.remove("hidden");
  }

  function scheduleAutoMediaReconnect(reason, delayMs = 0) {
    if (!AUTO_RECONNECT_ON_STALL || autoReconnectAttempts >= 1 || autoReconnectTimer) {
      return;
    }
    autoReconnectAttempts += 1;
    reportDebug(`auto reconnect scheduled: ${reason}`);
    autoReconnectTimer = window.setTimeout(() => {
      autoReconnectTimer = null;
      if (!pc || pc.connectionState !== "connected") {
        return;
      }
      if (videoEl.videoWidth > 0 && videoEl.videoHeight > 0) {
        noDecodedDimensionStats = 0;
        return;
      }
      reportDebug(`auto reconnect firing: ${reason}`);
      reconnect().catch((error) => {
        reportDebug(`auto reconnect failed: ${error.message || error}`);
      });
    }, delayMs);
  }

  function focusRemoteSurface() {
    if (canvasEl) {
      canvasEl.focus({ preventScroll: true });
    }
    playRemoteMedia();
    startDrawLoop();
  }

  function markInputCaptured() {
    if (inputCaptured) {
      return;
    }
    inputCaptured = true;
    dismissOverlay();
    focusRemoteSurface();
    applySettings();
    setStatus("input: capturing mouse/keyboard");
  }

  function playRemoteMedia() {
    if (videoEl && videoEl.srcObject) {
      startVideoFrameMonitor();
      const videoPromise = videoEl.play();
      if (videoPromise && typeof videoPromise.catch === "function") {
        videoPromise.catch((error) => {
          reportDebug(`video play failed: ${error.message || error}`);
          showResumeOverlay("Safari blocked video playback.");
        });
      }
    }
    if (!audioEl || !audioEl.srcObject) {
      return;
    }
    const playPromise = audioEl.play();
    if (playPromise && typeof playPromise.catch === "function") {
      playPromise.catch((error) => {
        reportDebug(`audio play failed: ${error.message || error}`);
        showResumeOverlay("Safari blocked audio playback.");
      });
    }
  }

  function startDrawLoop() {
    if (drawLoopStarted) {
      return;
    }
    drawLoopStarted = true;
    requestAnimationFrame(drawRemoteFrame);
  }

  function scheduleVideoWatchdog() {
    window.setTimeout(() => {
      if (!pc || pc.connectionState !== "connected") {
        return;
      }
      if (videoEl.videoWidth > 0 && videoEl.videoHeight > 0) {
        return;
      }
      reportDebug("video watchdog: connected but no decoded dimensions");
      showResumeOverlay(
        "Video signaling connected but no frames decoded.\n\n" +
          buildIceFailureHint("connected-without-video")
      );
      playRemoteMedia();
      scheduleAutoMediaReconnect("connected without decoded dimensions after watchdog", 7000);
    }, 3000);
  }

  function scheduleNextFrame() {
    requestAnimationFrame(drawRemoteFrame);
  }

  function drawRemoteFrame() {
    if (settings.renderMode === "direct") {
      applyVideoLayout();
      hideOverlayWhenPlaying();
      scheduleNextFrame();
      return;
    }
    if (!videoEl.videoWidth || !videoEl.videoHeight) {
      scheduleNextFrame();
      return;
    }

    const rect = canvasEl.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    const targetWidth = Math.max(1, Math.floor(rect.width * dpr));
    const targetHeight = Math.max(1, Math.floor(rect.height * dpr));

    if (canvasEl.width !== targetWidth || canvasEl.height !== targetHeight) {
      canvasEl.width = targetWidth;
      canvasEl.height = targetHeight;
    }

    const videoAspect = videoEl.videoWidth / videoEl.videoHeight;
    const canvasAspect = targetWidth / targetHeight;
    let drawWidth = settings.fitMode === "native" ? videoEl.videoWidth * dpr : targetWidth;
    let drawHeight = settings.fitMode === "native" ? videoEl.videoHeight * dpr : targetHeight;
    let x = 0;
    let y = 0;

    if (settings.fitMode === "stretch") {
      drawWidth = targetWidth;
      drawHeight = targetHeight;
    } else if (settings.fitMode === "native") {
      x = (targetWidth - drawWidth) / 2;
      y = (targetHeight - drawHeight) / 2;
    } else if (settings.fitMode === "cover") {
      if (canvasAspect > videoAspect) {
        drawHeight = targetWidth / videoAspect;
        y = (targetHeight - drawHeight) / 2;
      } else {
        drawWidth = targetHeight * videoAspect;
        x = (targetWidth - drawWidth) / 2;
      }
    } else if (canvasAspect > videoAspect) {
      drawWidth = targetHeight * videoAspect;
      x = (targetWidth - drawWidth) / 2;
    } else {
      drawHeight = targetWidth / videoAspect;
      y = (targetHeight - drawHeight) / 2;
    }

    canvasCtx.fillStyle = "#000";
    canvasCtx.imageSmoothingEnabled = Boolean(settings.videoSmoothing);
    canvasCtx.fillRect(0, 0, targetWidth, targetHeight);
    canvasCtx.drawImage(videoEl, x, y, drawWidth, drawHeight);
    hideOverlayWhenPlaying();

    scheduleNextFrame();
  }

  function applyVideoLayout() {
    if (!videoEl || settings.renderMode !== "direct") {
      return;
    }
    const surfaceRect = (surfaceEl || document.documentElement).getBoundingClientRect();
    const sourceWidth = videoEl.videoWidth || Number(params.get("width")) || 1024;
    const sourceHeight = videoEl.videoHeight || Number(params.get("height")) || 768;
    const sourceAspect = sourceWidth / sourceHeight;
    const surfaceAspect = surfaceRect.width / surfaceRect.height;
    let width = surfaceRect.width;
    let height = surfaceRect.height;

    if (settings.fitMode === "stretch") {
      width = surfaceRect.width;
      height = surfaceRect.height;
    } else if (settings.fitMode === "native") {
      width = sourceWidth;
      height = sourceHeight;
    } else if (settings.fitMode === "cover") {
      if (surfaceAspect > sourceAspect) {
        height = surfaceRect.width / sourceAspect;
      } else {
        width = surfaceRect.height * sourceAspect;
      }
    } else if (surfaceAspect > sourceAspect) {
      width = surfaceRect.height * sourceAspect;
    } else {
      height = surfaceRect.width / sourceAspect;
    }

    videoEl.style.width = `${Math.max(1, width)}px`;
    videoEl.style.height = `${Math.max(1, height)}px`;
  }

  function warnIfHevcUnsupported() {
    const codec = requestedCodec();
    if (codec !== "H265" && codec !== "HEVC") {
      return;
    }
    if (!window.RTCRtpReceiver || typeof RTCRtpReceiver.getCapabilities !== "function") {
      const message =
        "HEVC requested but this browser cannot report WebRTC decode support. Use H264 or noVNC fallback.";
      setStatus(`warning: ${message}`);
      showResumeOverlay(message);
      return;
    }
    if (!browserSupportsHevc()) {
      const message =
        "This browser cannot decode HEVC over WebRTC. Set WEBRTC_VIDEO_CODEC=H264 or use noVNC fallback.";
      setStatus(`warning: ${message}`);
      showResumeOverlay(message);
    } else {
      setStatus("HEVC mode: browser reports HEVC decode support");
    }
  }

  function attachStreamToVideo(track, streams) {
    const stream = new MediaStream([track]);
    if (track.kind === "audio") {
      audioEl.srcObject = stream;
      audioEl.muted = false;
      if (inputCaptured) {
        playRemoteMedia();
      }
      reportDebug(`audio track attached muted=${track.muted}`);
      return;
    }

    videoEl.srcObject = stream;
    videoEl.muted = true;
    videoEl.playsInline = true;
    videoEl.setAttribute("webkit-playsinline", "true");
    videoEl.controls = false;
    startVideoFrameMonitor();

    const play = () => {
      startVideoFrameMonitor();
      const playPromise = videoEl.play();
      if (playPromise && typeof playPromise.catch === "function") {
        playPromise.catch(() => {});
      }
    };

    track.onunmute = () => {
      setStatus(`track unmuted: ${track.kind} ${videoEl.videoWidth}x${videoEl.videoHeight}`);
      if (inputCaptured) {
        play();
      }
      startDrawLoop();
      hideOverlayWhenPlaying();
    };

    videoEl.addEventListener("loadedmetadata", () => {
      reportDebug(`video metadata ${videoEl.videoWidth}x${videoEl.videoHeight}`);
      hideOverlayWhenPlaying();
      startDrawLoop();
    });
    videoEl.addEventListener("resize", () => {
      reportDebug(`video resize ${videoEl.videoWidth}x${videoEl.videoHeight}`);
      hideOverlayWhenPlaying();
      startDrawLoop();
    });

    if (!track.muted) {
      if (inputCaptured) {
        play();
      }
      startDrawLoop();
      hideOverlayWhenPlaying();
    }
  }

  function configureReceiver(receiver) {
    if (receiver && "playoutDelayHint" in receiver) {
      receiver.playoutDelayHint = 0;
    }
  }

  async function flushPendingRemoteCandidates() {
    if (!remoteDescriptionSet || !pc) {
      return;
    }
    const queue = pendingRemoteCandidates.splice(0);
    for (const candidate of queue) {
      try {
        await pc.addIceCandidate(candidate);
      } catch (error) {
        console.warn("[remote] addIceCandidate failed", error);
      }
    }
  }

  async function applyRemoteDescription(description) {
    reportDebug(`setRemoteDescription ${description.type} sdpLen=${(description.sdp || "").length}`);
    await pc.setRemoteDescription(description);
    remoteDescriptionSet = true;
    await flushPendingRemoteCandidates();
  }

  async function createPeerConnection() {
    pc = new RTCPeerConnection({
      iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
      bundlePolicy: "max-bundle",
    });
    window.ra2Pc = pc;

    pc.ontrack = (event) => {
      configureReceiver(event.receiver);
      attachStreamToVideo(event.track, event.streams);
      setStatus(`track: ${event.track.kind} live=${event.track.readyState}`);
      reportDebug(`track ${event.track.kind} ready=${event.track.readyState} muted=${event.track.muted}`);
    };

    pc.onicecandidate = (event) => {
      if (!signalSocket || signalSocket.readyState !== WebSocket.OPEN) {
        return;
      }
      if (!event.candidate) {
        return;
      }
      const payload = {
        type: "ice",
        candidate: event.candidate.candidate,
        sdpMid: event.candidate.sdpMid,
        sdpMLineIndex: event.candidate.sdpMLineIndex,
      };
      if (!remoteDescriptionSet) {
        pendingLocalCandidates.push(payload);
        return;
      }
      signalSocket.send(JSON.stringify(payload));
    };

    pc.onconnectionstatechange = () => {
      setStatus(`peer: ${pc.connectionState}`);
      reportDebug(`peer state ${pc.connectionState}`);
      if (pc.connectionState === "connected") {
        scheduleVideoWatchdog();
        startStatsReporter();
      }
      if (pc.connectionState === "failed" || pc.connectionState === "disconnected") {
        reportDebug(`media failure peer=${pc.connectionState} ice=${pc.iceConnectionState}`);
        showIceFailureOverlay(`${pc.connectionState} (ice=${pc.iceConnectionState})`);
      }
      if (pc.connectionState === "closed") {
        stopStatsReporter();
      }
    };

    pc.oniceconnectionstatechange = () => {
      setStatus(`ice: ${pc.iceConnectionState}`);
      reportDebug(`ice state ${pc.iceConnectionState}`);
      if (pc.iceConnectionState === "checking" && !iceCheckingStartedAt) {
        iceCheckingStartedAt = performance.now();
      }
      if (pc.iceConnectionState === "failed") {
        showIceFailureOverlay("failed");
      } else if (pc.iceConnectionState === "disconnected") {
        showIceFailureOverlay("disconnected");
      } else if (pc.iceConnectionState === "connected") {
        iceCheckingStartedAt = 0;
      } else if (
        pc.iceConnectionState === "checking" &&
        iceCheckingStartedAt &&
        performance.now() - iceCheckingStartedAt > 15000
      ) {
        showIceFailureOverlay("checking-timeout");
        iceCheckingStartedAt = 0;
      }
    };
  }

  async function handleSignalMessage(raw) {
    const data = JSON.parse(raw);
    if (data.type === "offer") {
      await applyRemoteDescription({ type: "offer", sdp: data.sdp });
      const answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      signalSocket.send(JSON.stringify({ type: "answer", sdp: answer.sdp }));
      for (const payload of pendingLocalCandidates.splice(0)) {
        signalSocket.send(JSON.stringify(payload));
      }
      setStatus("answer sent");
      return;
    }

    if (data.type === "ice") {
      if (!data.candidate) {
        return;
      }
      const candidate = {
        candidate: data.candidate,
        sdpMid: data.sdpMid || null,
        sdpMLineIndex: data.sdpMLineIndex,
      };
      noteRemoteCandidate(data.candidate);
      if (!remoteDescriptionSet) {
        pendingRemoteCandidates.push(candidate);
        return;
      }
      try {
        await pc.addIceCandidate(candidate);
      } catch (error) {
        console.warn("[remote] addIceCandidate failed", error);
      }
    }
  }

  async function connectInput() {
    window.ra2InputSocket = null;
    try {
      inputSocket = await connectWithFallback(inputSchemes, inputPort, {
        onOpen: (url) => {
          window.ra2InputUrl = url;
          window.ra2InputSocket = inputSocket;
          window.ra2InputConnected = true;
          setStatus("input: connected — click surface to capture");
          reportDebug(`input connected url=${url}`);
        },
        onClose: () => {
          window.ra2InputConnected = false;
          setStatus("input: disconnected");
        },
      });
      window.ra2InputSocket = inputSocket;
    } catch (error) {
      window.ra2InputConnected = false;
      setStatus(`input: error (${error.message || error})`);
      reportDebug(`input connect failed: ${error.message || error}`);
    }
  }

  function sendInput(payload) {
    if (!inputSocket || inputSocket.readyState !== WebSocket.OPEN) {
      return;
    }
    inputSocket.send(JSON.stringify(payload));
  }

  function remotePoint(event) {
    const rect = canvasEl.getBoundingClientRect();
    const videoAspect = (videoEl.videoWidth || 1280) / (videoEl.videoHeight || 720);
    const rectAspect = rect.width / rect.height;
    let xOffset = 0;
    let yOffset = 0;
    let drawWidth = rect.width;
    let drawHeight = rect.height;

    if (settings.fitMode === "stretch") {
      drawWidth = rect.width;
      drawHeight = rect.height;
    } else if (settings.fitMode === "native") {
      drawWidth = videoEl.videoWidth || 1280;
      drawHeight = videoEl.videoHeight || 720;
      xOffset = (rect.width - drawWidth) / 2;
      yOffset = (rect.height - drawHeight) / 2;
    } else if (settings.fitMode === "cover") {
      if (rectAspect > videoAspect) {
        drawHeight = rect.width / videoAspect;
        yOffset = (rect.height - drawHeight) / 2;
      } else {
        drawWidth = rect.height * videoAspect;
        xOffset = (rect.width - drawWidth) / 2;
      }
    } else if (rectAspect > videoAspect) {
      drawWidth = rect.height * videoAspect;
      xOffset = (rect.width - drawWidth) / 2;
    } else {
      drawHeight = rect.width / videoAspect;
      yOffset = (rect.height - drawHeight) / 2;
    }

    const x = Math.max(0, Math.min(1, (event.clientX - rect.left - xOffset) / drawWidth));
    const y = Math.max(0, Math.min(1, (event.clientY - rect.top - yOffset) / drawHeight));
    return {
      x: Math.round(x * (videoEl.videoWidth || 1280)),
      y: Math.round(y * (videoEl.videoHeight || 720)),
    };
  }

  function pointerButton(event) {
    if (event.button === 2) {
      return 3;
    }
    if (event.button === 1) {
      return 2;
    }
    return 1;
  }

  function xdotoolKey(event) {
    const keyMap = {
      " ": "space",
      ArrowUp: "Up",
      ArrowDown: "Down",
      ArrowLeft: "Left",
      ArrowRight: "Right",
      Enter: "Return",
      Escape: "Escape",
      Backspace: "BackSpace",
      Delete: "Delete",
      Tab: "Tab",
    };
    if (keyMap[event.key]) {
      return keyMap[event.key];
    }
    if (event.key && event.key.length === 1) {
      return event.key;
    }
    return event.key || "";
  }

  function bindPointerInput(target) {
    let pendingMove = null;
    let moveFlushTimer = null;
    let lastMoveSentAt = 0;

    function flushPendingMove() {
      moveFlushTimer = null;
      if (!pendingMove) {
        return;
      }
      sendInput({ type: "mousemove", ...pendingMove });
      inputMoveSent += 1;
      lastMoveSentAt = performance.now();
      pendingMove = null;
    }

    function scheduleMoveFlush(delayMs) {
      if (moveFlushTimer !== null) {
        return;
      }
      moveFlushTimer = window.setTimeout(flushPendingMove, Math.max(0, delayMs));
    }

    target.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      if (activePointerId !== null && activePointerId !== event.pointerId) {
        return;
      }
      activePointerId = event.pointerId;
      if (target.setPointerCapture) {
        try {
          target.setPointerCapture(event.pointerId);
        } catch (error) {
          console.warn("[remote] setPointerCapture failed", error);
        }
      }
      markInputCaptured();
      const point = remotePoint(event);
      sendInput({ type: "mousemove", ...point });
      sendInput({ type: "mousedown", ...point, button: pointerButton(event) });
    });

    target.addEventListener("pointermove", (event) => {
      if (!inputCaptured) {
        return;
      }
      if (activePointerId !== null && event.pointerId !== activePointerId) {
        return;
      }
      pendingMove = remotePoint(event);
      const now = performance.now();
      const elapsed = now - lastMoveSentAt;
      if (elapsed < INPUT_MOVE_INTERVAL_MS) {
        inputMoveDropped += 1;
        scheduleMoveFlush(INPUT_MOVE_INTERVAL_MS - elapsed);
        return;
      }
      if (moveFlushTimer !== null) {
        window.clearTimeout(moveFlushTimer);
        moveFlushTimer = null;
      }
      flushPendingMove();
    });

    target.addEventListener("pointerup", (event) => {
      event.preventDefault();
      if (activePointerId !== null && event.pointerId !== activePointerId) {
        return;
      }
      const point = remotePoint(event);
      sendInput({ type: "mousemove", ...point });
      sendInput({ type: "mouseup", ...point, button: pointerButton(event) });
      activePointerId = null;
      if (target.releasePointerCapture) {
        try {
          target.releasePointerCapture(event.pointerId);
        } catch (error) {
          console.warn("[remote] releasePointerCapture failed", error);
        }
      }
    });

    target.addEventListener("pointercancel", () => {
      activePointerId = null;
    });
  }

  function bindRemoteInput() {
    if (!canvasEl) {
      return;
    }

    canvasEl.addEventListener("wheel", (event) => {
      if (!inputCaptured) {
        return;
      }
      event.preventDefault();
      sendInput({ type: "wheel", deltaY: event.deltaY });
    }, { passive: false });

    canvasEl.addEventListener("keydown", (event) => {
      if (!inputCaptured) {
        return;
      }
      event.preventDefault();
      sendInput({ type: "keydown", key: xdotoolKey(event) });
    });
    canvasEl.addEventListener("keyup", (event) => {
      if (!inputCaptured) {
        return;
      }
      event.preventDefault();
      sendInput({ type: "keyup", key: xdotoolKey(event) });
    });

    canvasEl.addEventListener("contextmenu", (event) => event.preventDefault());
    bindPointerInput(canvasEl);
  }

  function activeFullscreenElement() {
    return document.fullscreenElement || document.webkitFullscreenElement || null;
  }

  async function toggleFullscreen() {
    const target = surfaceEl || document.documentElement;
    try {
      if (activeFullscreenElement()) {
        if (document.exitFullscreen) {
          await document.exitFullscreen();
        } else if (document.webkitExitFullscreen) {
          document.webkitExitFullscreen();
        }
        return;
      }
      if (target.requestFullscreen) {
        await target.requestFullscreen({ navigationUI: "hide" });
      } else if (target.webkitRequestFullscreen) {
        target.webkitRequestFullscreen();
      }
      focusRemoteSurface();
    } catch (error) {
      setStatus(`fullscreen failed: ${error.message || error}`);
    }
  }

  async function requestPointerLock() {
    try {
      focusRemoteSurface();
      if (canvasEl.requestPointerLock) {
        await canvasEl.requestPointerLock();
      } else if (canvasEl.webkitRequestPointerLock) {
        canvasEl.webkitRequestPointerLock();
      }
    } catch (error) {
      setStatus(`pointer lock failed: ${error.message || error}`);
    }
  }

  async function reconnect() {
    setStatus("reconnecting media…");
    stopStatsReporter();
    lastDecodedFrameCount = 0;
    frameStalls = 0;
    presentedVideoFrames = 0;
    lastPresentedVideoFrames = 0;
    lastPresentedVideoFrameAt = 0;
    paintStalls = 0;
    noDecodedDimensionStats = 0;
    if (autoReconnectTimer) {
      window.clearTimeout(autoReconnectTimer);
      autoReconnectTimer = null;
    }
    inputMoveSent = 0;
    inputMoveDropped = 0;
    if (signalSocket) {
      signalSocket.onclose = null;
      signalSocket.close();
      signalSocket = null;
    }
    if (inputSocket) {
      inputSocket.onclose = null;
      inputSocket.close();
      inputSocket = null;
      window.ra2InputSocket = null;
      window.ra2InputConnected = false;
    }
    if (pc) {
      pc.close();
      pc = null;
      window.ra2Pc = null;
    }
    remoteDescriptionSet = false;
    pendingRemoteCandidates = [];
    pendingLocalCandidates = [];
    inputCaptured = false;
    drawLoopStarted = false;
    connectSignal().catch((error) => {
      setStatus(`signal: error (${error.message || error})`);
      reportDebug(`signal connect failed: ${error.message || error}`);
    });
    connectInput();
  }

  function toggleSettingsPanel(forceOpen) {
    if (!settingsPanel || !settingsButton) {
      return;
    }
    const open = typeof forceOpen === "boolean" ? forceOpen : settingsPanel.classList.contains("hidden");
    settingsPanel.classList.toggle("hidden", !open);
    settingsButton.setAttribute("aria-expanded", String(open));
  }

  function bindSettingsControls() {
    if (settingsPanel) {
      settingsPanel.addEventListener("pointerdown", (event) => event.stopPropagation());
      settingsPanel.addEventListener("click", (event) => event.stopPropagation());
      settingsPanel.addEventListener("keydown", (event) => event.stopPropagation());
    }
    settingsButton?.addEventListener("click", (event) => {
      event.stopPropagation();
      toggleSettingsPanel();
    });
    settingsClose?.addEventListener("click", () => toggleSettingsPanel(false));
    fitModeEl?.addEventListener("change", () => updateSetting("fitMode", fitModeEl.value));
    renderModeEl?.addEventListener("change", () => updateSetting("renderMode", renderModeEl.value));
    audioVolumeEl?.addEventListener("input", () => updateSetting("audioVolume", Number(audioVolumeEl.value)));
    showCursorEl?.addEventListener("change", () => updateSetting("showCursor", showCursorEl.checked));
    showControlsEl?.addEventListener("change", () => updateSetting("showControls", showControlsEl.checked));
    videoSmoothingEl?.addEventListener("change", () => updateSetting("videoSmoothing", videoSmoothingEl.checked));
    fullscreenButton?.addEventListener("click", toggleFullscreen);
    pointerLockButton?.addEventListener("click", requestPointerLock);
    reconnectButton?.addEventListener("click", reconnect);
    reloadButton?.addEventListener("click", () => window.location.reload());
    document.addEventListener("fullscreenchange", () => {
      if (fullscreenButton) {
        fullscreenButton.textContent = activeFullscreenElement() ? "Exit fullscreen" : "Fullscreen";
      }
    });
    document.addEventListener("webkitfullscreenchange", () => {
      if (fullscreenButton) {
        fullscreenButton.textContent = activeFullscreenElement() ? "Exit fullscreen" : "Fullscreen";
      }
    });
  }

  function openWebSocket(url, handlers) {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(url);
      let settled = false;
      const finish = (error) => {
        if (settled) {
          return;
        }
        settled = true;
        if (error) {
          reject(error);
        } else {
          resolve(socket);
        }
      };
      socket.addEventListener("open", () => finish());
      socket.addEventListener("error", () => finish(new Error(`connect failed (${url})`)));
      socket.addEventListener("close", () => {
        handlers.onClose?.();
        if (!settled) {
          finish(new Error(`closed before open (${url})`));
        }
      });
      socket.addEventListener("message", (event) => handlers.onMessage?.(event));
    });
  }

  async function connectWithFallback(schemes, port, handlers) {
    let lastError = null;
    for (const scheme of schemes) {
      const url = `${scheme}://${host}:${port}`;
      try {
        const socket = await openWebSocket(url, handlers);
        handlers.onOpen?.(url);
        return socket;
      } catch (error) {
        lastError = error;
        reportDebug(`socket fallback ${url}: ${error.message || error}`);
      }
    }
    throw lastError || new Error("no socket schemes left to try");
  }

  async function connectSignal() {
    warnIfHevcUnsupported();
    videoEl.controls = false;
    videoEl.disablePictureInPicture = true;
    videoEl.setAttribute("controlsList", "nodownload nofullscreen noremoteplayback");
    await createPeerConnection();
    signalSocket = await connectWithFallback(signalSchemes, signalPort, {
      onOpen: (url) => {
        setStatus(`signal: connected (${url})`);
        reportDebug(`signal connected ${url}`);
      },
      onClose: () => setStatus("signal: disconnected"),
      onMessage: async (event) => {
        try {
          await handleSignalMessage(event.data);
        } catch (error) {
          console.error("[remote] signal handler failed", error);
          setStatus(`signal error: ${error.message || error}`);
          reportDebug(`signal handler failed: ${error.message || error}`);
        }
      },
    });
  }

  function bindOverlayInput() {
    if (!overlayEl) {
      return;
    }
    overlayEl.addEventListener("contextmenu", (event) => event.preventDefault());
    bindPointerInput(overlayEl);
  }

  if (videoEl) {
    videoEl.addEventListener("playing", () => reportDebug(`video playing ${videoEl.videoWidth}x${videoEl.videoHeight}`));
    videoEl.addEventListener("error", () => reportDebug("video element error"));
  }
  window.addEventListener("resize", applyVideoLayout);
  if (audioEl) {
    audioEl.addEventListener("playing", () => reportDebug("audio playing"));
    audioEl.addEventListener("error", () => reportDebug("audio element error"));
  }

  applySettings();
  connectSignal().catch((error) => {
    setStatus(`signal: error (${error.message || error})`);
    reportDebug(`signal connect failed: ${error.message || error}`);
  });
  connectInput();
  bindRemoteInput();
  bindOverlayInput();
  bindSettingsControls();
  setInterval(hideOverlayWhenPlaying, 500);
})();
