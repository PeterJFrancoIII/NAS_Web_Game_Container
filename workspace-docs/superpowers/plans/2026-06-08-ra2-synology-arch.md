# RA2 Synology Arch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained Synology DS225+ Docker project that runs two lightweight Arch Linux Red Alert 2/Yuri's Revenge instances with browser display and static internal container IPs.

**Architecture:** Use one shared Arch Linux image and two Compose services. Each service has its own persistent Wine prefix and static IP on a private Docker bridge; clients connect to noVNC through different host ports on the NAS.

**Tech Stack:** Docker Compose, Arch Linux, Wine WoW64, Xvfb, Openbox, x11vnc, noVNC, websockify, cnc-ddraw, IPX-to-UDP wrapper.

---

## File Structure

- `synology-ra2-arch/compose.yaml`: two-player stack, static internal IPs, browser ports, resource caps.
- `synology-ra2-arch/.env.example`: deployment defaults for NAS paths, ports, passwords, and per-player serials.
- `synology-ra2-arch/container/Dockerfile`: minimal Arch runtime image with Wine and the noVNC display pipeline.
- `synology-ra2-arch/container/entrypoint.sh`: validates mounted assets, initializes Wine prefix, injects registry values, starts supervisord.
- `synology-ra2-arch/container/supervisord.conf`: starts Xvfb, Openbox, x11vnc, websockify, and RA2.
- `synology-ra2-arch/config/ddraw.ini`: cnc-ddraw baseline optimized for noVNC.
- `synology-ra2-arch/config/RA2.ini` and `synology-ra2-arch/config/RA2MD.ini`: video/network defaults to copy into game assets.
- `synology-ra2-arch/scripts/prepare-nas.sh`: creates Synology directory layout under `/volume2/Data/App_Development/ra2-lan-party`.
- `synology-ra2-arch/docs/DEPLOY_SYNOLOGY.md`: operator deployment and troubleshooting guide.
- `synology-ra2-arch/README.md`: project overview, constraints, and quick start.

### Task 1: Compose And Environment

**Files:**
- Create: `synology-ra2-arch/compose.yaml`
- Create: `synology-ra2-arch/.env.example`

- [ ] **Step 1: Write Compose stack**

Create two services, `ra2-player-1` and `ra2-player-2`, both built from `container/Dockerfile`. Assign `172.22.20.11` and `172.22.20.12` on `ra2_lan`, map host ports `6081` and `6082`, mount shared assets read-only, and mount separate Wine prefixes read-write.

- [ ] **Step 2: Add deploy defaults**

Add `.env.example` with `/volume2/Data/App_Development/ra2-lan-party` paths, safe placeholder VNC passwords, unique serial placeholders, `1024x768`, and `RA2MD.exe` as the default executable.

- [ ] **Step 3: Verify syntax**

Run `docker compose --env-file .env.example config` from `synology-ra2-arch`. Expected: a fully rendered config with two services and no YAML errors.

### Task 2: Runtime Image And Startup

**Files:**
- Create: `synology-ra2-arch/container/Dockerfile`
- Create: `synology-ra2-arch/container/entrypoint.sh`
- Create: `synology-ra2-arch/container/supervisord.conf`

- [ ] **Step 1: Build minimal Arch image**

Install only Wine, Xvfb, Openbox, x11vnc, supervisor, ALSA libraries, Mesa software rendering, Python, and noVNC/websockify. Run as a non-root `commander` user.

- [ ] **Step 2: Initialize Wine prefix**

In `entrypoint.sh`, validate that the mounted game directory contains the selected executable, initialize the prefix once, copy assets into `C:\RA2`, write dummy ALSA and unique serial registry values, then start supervisord.

- [ ] **Step 3: Start supervised processes**

Run Xvfb at 16-bit depth, Openbox, x11vnc bound to localhost, websockify/noVNC on port `6080`, and the configured game executable through Wine.

### Task 3: Game Config And NAS Docs

**Files:**
- Create: `synology-ra2-arch/config/ddraw.ini`
- Create: `synology-ra2-arch/config/RA2.ini`
- Create: `synology-ra2-arch/config/RA2MD.ini`
- Create: `synology-ra2-arch/scripts/prepare-nas.sh`
- Create: `synology-ra2-arch/docs/DEPLOY_SYNOLOGY.md`
- Create: `synology-ra2-arch/README.md`

- [ ] **Step 1: Provide config templates**

Add cnc-ddraw and RA2 video/network configs for `1024x768`, no back buffer, and LAN-friendly defaults.

- [ ] **Step 2: Provide NAS preparation script**

Create directories under `/volume2/Data/App_Development/ra2-lan-party` for assets, prefixes, project files, and logs. Do not download or create copyrighted game assets.

- [ ] **Step 3: Document deployment**

Explain asset requirements, legal ownership caveat, `docker compose` commands, browser URLs, static container IPs, Synology firewall allowance for `172.22.20.0/24`, and troubleshooting steps.

### Task 4: Review And Verification

**Files:**
- Read/review all created project files.

- [ ] **Step 1: Static validation**

Run local YAML/config validation where available. If Docker is unavailable locally, document that verification is limited to static file review.

- [ ] **Step 2: Subagent review**

Dispatch read-only review for spec compliance and operational risks. Fix any clear issues.

- [ ] **Step 3: Final summary**

Report created files, what was verified, and what must be completed on the NAS with licensed game files.
