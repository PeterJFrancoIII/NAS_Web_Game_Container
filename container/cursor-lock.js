(() => {
  const TOGGLE_SHORTCUT = "Ctrl+Alt+L";
  const LOCKED_CLASS = "ra2-cursor-locked";
  const SYNTHETIC_MARKER = "__ra2CursorLockSynthetic";
  const INTERCEPTED_EVENTS = ["mousemove", "mousedown", "mouseup", "click", "dblclick", "contextmenu", "wheel"];

  let target = null;
  let virtualX = 0;
  let virtualY = 0;
  let panel = null;

  function findTarget() {
    return (
      document.querySelector("#noVNC_container canvas") ||
      document.querySelector("#noVNC_screen canvas") ||
      document.querySelector("#noVNC_container") ||
      document.querySelector("#noVNC_screen") ||
      document.querySelector("canvas")
    );
  }

  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  function targetRect() {
    const element = target || findTarget();
    return element ? element.getBoundingClientRect() : null;
  }

  function setStatus(text) {
    if (panel) {
      panel.querySelector("[data-cursor-lock-status]").textContent = text;
    }
  }

  function isLocked() {
    return Boolean(target && document.pointerLockElement === target);
  }

  function updateButton() {
    if (!panel) {
      return;
    }
    const locked = isLocked();
    panel.querySelector("[data-cursor-lock-toggle]").textContent = locked ? "unlock mouse" : "lock mouse";
    setStatus(locked ? `${TOGGLE_SHORTCUT} or Esc unlocks` : `${TOGGLE_SHORTCUT} locks`);
    document.documentElement.classList.toggle(LOCKED_CLASS, locked);
  }

  function dispatchSyntheticEvent(originalEvent) {
    if (!target) {
      return;
    }

    const rect = targetRect();
    if (!rect) {
      return;
    }

    if (originalEvent.type === "mousemove") {
      virtualX = clamp(virtualX + originalEvent.movementX, rect.left, rect.right - 1);
      virtualY = clamp(virtualY + originalEvent.movementY, rect.top, rect.bottom - 1);
    }

    const init = {
      bubbles: true,
      cancelable: true,
      composed: true,
      view: window,
      detail: originalEvent.detail,
      screenX: originalEvent.screenX,
      screenY: originalEvent.screenY,
      clientX: virtualX,
      clientY: virtualY,
      ctrlKey: originalEvent.ctrlKey,
      altKey: originalEvent.altKey,
      shiftKey: originalEvent.shiftKey,
      metaKey: originalEvent.metaKey,
      button: originalEvent.button,
      buttons: originalEvent.buttons,
      relatedTarget: originalEvent.relatedTarget,
    };

    let syntheticEvent;
    if (originalEvent instanceof WheelEvent) {
      syntheticEvent = new WheelEvent(originalEvent.type, {
        ...init,
        deltaX: originalEvent.deltaX,
        deltaY: originalEvent.deltaY,
        deltaZ: originalEvent.deltaZ,
        deltaMode: originalEvent.deltaMode,
      });
    } else {
      syntheticEvent = new MouseEvent(originalEvent.type, {
        ...init,
        movementX: originalEvent.movementX,
        movementY: originalEvent.movementY,
      });
    }

    Object.defineProperty(syntheticEvent, SYNTHETIC_MARKER, { value: true });
    target.dispatchEvent(syntheticEvent);
  }

  function interceptPointerEvent(event) {
    if (!isLocked() || event[SYNTHETIC_MARKER]) {
      return;
    }

    event.preventDefault();
    event.stopImmediatePropagation();
    dispatchSyntheticEvent(event);
  }

  async function requestLock() {
    target = findTarget();
    if (!target) {
      setStatus("no noVNC canvas yet");
      return;
    }

    const rect = targetRect();
    virtualX = rect ? rect.left + rect.width / 2 : 0;
    virtualY = rect ? rect.top + rect.height / 2 : 0;

    try {
      if (target.requestFullscreen && document.fullscreenElement !== target) {
        await target.requestFullscreen();
      }
      await target.requestPointerLock();
    } catch (error) {
      setStatus(`lock blocked: ${error.name || "browser"}`);
    } finally {
      updateButton();
    }
  }

  async function releaseLock() {
    if (document.pointerLockElement) {
      document.exitPointerLock();
    }
    if (document.fullscreenElement && document.exitFullscreen) {
      try {
        await document.exitFullscreen();
      } catch {
        // Fullscreen can already be exiting when Esc is pressed.
      }
    }
    updateButton();
  }

  function toggleLock() {
    if (isLocked()) {
      releaseLock();
    } else {
      requestLock();
    }
  }

  function createPanel() {
    panel = document.createElement("section");
    panel.id = "ra2_cursor_lock";
    panel.innerHTML = `
      <style>
        #ra2_cursor_lock {
          position: fixed;
          left: 12px;
          bottom: 12px;
          z-index: 10001;
          width: 230px;
          padding: 10px 12px;
          color: #f4f4f4;
          background: rgba(14, 18, 24, 0.88);
          border: 1px solid rgba(255,255,255,0.22);
          border-radius: 8px;
          font: 12px/1.35 system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          box-shadow: 0 8px 22px rgba(0,0,0,0.35);
        }
        #ra2_cursor_lock button {
          color: #9bd3ff;
          background: transparent;
          border: 0;
          padding: 0;
          font: inherit;
          text-decoration: underline;
          cursor: pointer;
        }
        #ra2_cursor_lock .muted { color: #b8c4d0; margin-top: 4px; }
        .${LOCKED_CLASS} #ra2_cursor_lock {
          border-color: rgba(139, 211, 255, 0.75);
        }
      </style>
      <strong>Mouse lock</strong>
      <div><button type="button" data-cursor-lock-toggle>lock mouse</button></div>
      <div class="muted" data-cursor-lock-status>${TOGGLE_SHORTCUT} locks</div>
    `;

    panel.querySelector("[data-cursor-lock-toggle]").addEventListener("click", toggleLock);
    document.body.appendChild(panel);
    updateButton();
  }

  window.addEventListener("DOMContentLoaded", createPanel);
  document.addEventListener("pointerlockchange", updateButton);
  document.addEventListener("fullscreenchange", updateButton);
  document.addEventListener("keydown", (event) => {
    if (event.ctrlKey && event.altKey && event.code === "KeyL") {
      event.preventDefault();
      toggleLock();
    }
  });

  for (const eventName of INTERCEPTED_EVENTS) {
    document.addEventListener(eventName, interceptPointerEvent, true);
  }
})();
