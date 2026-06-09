(() => {
  const params = new URLSearchParams(window.location.search);
  const signalPort = params.get("signal") || params.get("signal_port") || "6091";
  const inputPort = params.get("input") || params.get("input_port") || "5731";
  const host = window.location.hostname;
  const secure = window.location.protocol === "https:";
  const wsScheme = secure ? "wss" : "ws";

  const statusEl = document.getElementById("status");
  const videoEl = document.getElementById("remoteVideo");
  let pc = null;
  let signalSocket = null;
  let inputSocket = null;

  function setStatus(text) {
    statusEl.textContent = text;
  }

  function signalUrl() {
    return `${wsScheme}://${host}:${signalPort}/`;
  }

  function inputUrl() {
    return `${wsScheme}://${host}:${inputPort}/`;
  }

  async function start() {
    setStatus("signaling…");
    pc = new RTCPeerConnection({
      iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
    });

    pc.ontrack = (event) => {
      if (!videoEl.srcObject) {
        videoEl.srcObject = event.streams[0];
      } else {
        event.streams[0].getTracks().forEach((track) => {
          videoEl.srcObject.addTrack(track);
        });
      }
      setStatus("streaming");
    };

    pc.onicecandidate = (event) => {
      if (event.candidate && signalSocket?.readyState === WebSocket.OPEN) {
        signalSocket.send(
          JSON.stringify({
            type: "ice",
            candidate: event.candidate.candidate,
            sdpMLineIndex: event.candidate.sdpMLineIndex,
          })
        );
      }
    };

    pc.onconnectionstatechange = () => {
      setStatus(`peer: ${pc.connectionState}`);
    };

    signalSocket = new WebSocket(signalUrl());
    signalSocket.addEventListener("open", () => setStatus("signal connected"));
    signalSocket.addEventListener("message", async (event) => {
      const data = JSON.parse(event.data);
      if (data.type === "offer") {
        await pc.setRemoteDescription({ type: "offer", sdp: data.sdp });
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        signalSocket.send(JSON.stringify({ type: "answer", sdp: answer.sdp }));
        setStatus("answer sent");
      } else if (data.type === "ice") {
        await pc.addIceCandidate({
          candidate: data.candidate,
          sdpMLineIndex: data.sdpMLineIndex,
        });
      }
    });
    signalSocket.addEventListener("close", () => setStatus("signal disconnected"));

    connectInput();
    bindInputCapture();
  }

  function connectInput() {
    inputSocket = new WebSocket(inputUrl());
    inputSocket.addEventListener("open", () => setStatus("input connected"));
    inputSocket.addEventListener("close", () => setStatus("input disconnected"));
  }

  function sendInput(event) {
    if (!inputSocket || inputSocket.readyState !== WebSocket.OPEN) {
      return;
    }
    inputSocket.send(JSON.stringify(event));
  }

  function bindInputCapture() {
    const rect = () => videoEl.getBoundingClientRect();

    videoEl.addEventListener("click", () => {
      videoEl.focus();
      if (videoEl.requestPointerLock) {
        videoEl.requestPointerLock();
      }
    });

    videoEl.addEventListener("mousemove", (event) => {
      const r = rect();
      const scaleX = videoEl.videoWidth / r.width || 1;
      const scaleY = videoEl.videoHeight / r.height || 1;
      const x = Math.round((event.clientX - r.left) * scaleX);
      const y = Math.round((event.clientY - r.top) * scaleY);
      sendInput({ type: "mousemove", x, y });
    });

    videoEl.addEventListener("mousedown", (event) => {
      const r = rect();
      const scaleX = videoEl.videoWidth / r.width || 1;
      const scaleY = videoEl.videoHeight / r.height || 1;
      sendInput({
        type: "mousedown",
        button: event.button + 1,
        x: Math.round((event.clientX - r.left) * scaleX),
        y: Math.round((event.clientY - r.top) * scaleY),
      });
    });

    videoEl.addEventListener("mouseup", (event) => {
      sendInput({ type: "mouseup", button: event.button + 1 });
    });

    videoEl.addEventListener("wheel", (event) => {
      event.preventDefault();
      sendInput({ type: "wheel", deltaY: event.deltaY });
    });

    window.addEventListener("keydown", (event) => {
      sendInput({ type: "keydown", key: event.key });
    });

    window.addEventListener("keyup", (event) => {
      sendInput({ type: "keyup", key: event.key });
    });
  }

  window.addEventListener("DOMContentLoaded", () => {
    start().catch((error) => setStatus(`error: ${error.message}`));
  });
})();
