# **Comparative Analysis and Deployment Blueprint for Ultra-Low Latency Web-Based Remote Rendering on Synology DS225+**

The architectural demand for real-time video streaming has accelerated with the development of highly interactive applications such as cloud gaming, extended reality (XR), and remote desktop virtualization.1 End-to-end latency in cloud gaming must remain strictly under 100 milliseconds to prevent noticeable delay for players, with competitive first-person shooters requiring latencies below 20 milliseconds to approach the threshold of human perception.1  
While native client applications have historically dominated high-performance remote rendering, modern web-browser-based remote playback platforms have closed the performance gap.3 By leveraging thin-client browsers as zero-install endpoints, these web-based systems eliminate deployment barriers.4  
This report evaluates the leading ultra-low latency web-based remote rendering architectures, details the technical mechanisms that facilitate sub-30ms browser streaming, and provides an engineering blueprint for deploying a self-hosted remote gaming system on a Synology DS225+ Network Attached Storage (NAS) device.

## **1\. Landscape of Web-Based Remote Rendering and Display Protocols**

Historically, web-based remote desktop control was limited to Virtual Network Computing (VNC) architectures using the Remote Framebuffer (RFB) protocol or Remote Desktop Protocol (RDP) wrappers like Apache Guacamole.4 These legacy stacks suffer from high latency, poor color fidelity, and severe CPU overhead because they rely on continuous polling, image compression, and TCP-based frame delivery.4  
To achieve the performance required for interactive gaming, several specialized web-native remote rendering systems have emerged.

### **DeepLink Protocol**

DeepLink represents a decentralized, artificial intelligence (AI)-powered cloud gaming protocol built on the DeepBrain Chain.9 It leverages a hybrid peer-to-peer (HP2P) network architecture consisting of structured Chord ring layers and unstructured group-based layers to maintain network stability despite frequent node churn.9  
By deploying decentralized graphics processing unit (GPU) mining nodes and Genesis Traffic Nodes globally, DeepLink distributes the rendering load across a edge-computing network.9 The platform incorporates AI-driven super-resolution algorithms and dynamic network optimization to claim end-to-end latencies as low as 1 millisecond and stream configurations up to 8K at 244 Hz.9  
While highly scalable, its reliance on blockchain infrastructure and decentralized public chain consensus makes it less suited for localized, personal self-hosting.

### **Selkies (Selkies-GStreamer)**

Developed initially by Google engineers and subsequently maintained by academic researchers and open-source contributors, Selkies is a low-latency, GPU/CPU-accelerated WebRTC HTML5 remote desktop platform.10 Selkies replaces the entire legacy RFB stack with an optimized WebRTC pipeline built directly on a standalone GStreamer framework.4  
Rather than scraping an existing X11 or Wayland session, Selkies runs an in-container Rust-based Wayland compositor (Smithay) paired with the Labwc window manager.13 This design enables direct userspace access to GPU resources and zero-copy hardware encoding, delivering at least 60 frames per second at Full HD resolution directly to any modern web browser.4

### **Games on Whales (Wolf)**

Wolf is an open-source, headless streaming server developed by the Games on Whales project.16 It acts as a multi-user, Moonlight-compatible host that deploys exclusively within unprivileged Docker containers.4  
Wolf isolates multiple concurrent graphical sessions on a single remote machine by spinning up virtual hardware-accelerated desktops on demand, with full resolution and frame-rate matching.16 Under the hood, Wolf utilizes a micro-Wayland compositor (gst-wayland-display) compiled as a GStreamer plugin to capture the virtual display buffer and pipe it directly to the streaming engine.16  
By implementing the Moonlight protocol, Wolf achieves ultra-low latency streaming to various client devices, while its companion web application, Wolf Den, facilitates in-browser WebRTC session management and device pairing.16

### **Moonlight-Web-Stream**

Moonlight-Web-Stream is a web-native proxy server designed by independent developer MrCreativ3001.20 It acts as a bridge between a self-hosted Sunshine or Apollo host on the backend and a standard web browser on the frontend.21  
The server manages the Sunshine streaming lifecycle on the host machine and forwards the captured H.264/H.265 video and audio feeds to the browser via WebRTC.21 Crucially, it translates browser-native keyboard, mouse, and gamepad inputs (polled via the HTML5 Gamepad API) back into Sunshine’s virtual input drivers.21  
This architecture allows users to access their high-performance PC game libraries from locked-down or thin-client environments (such as Tesla console screens or managed workstations) without installing a dedicated client application.23

| Architectural Attribute | DeepLink | Selkies | Games on Whales (Wolf) | Moonlight-Web-Stream |
| :---- | :---- | :---- | :---- | :---- |
| **Streaming Protocol** | Proprietary P2P 9 | WebRTC / custom WebSocket 4 | Moonlight (RTSP/UDP) / WebRTC 16 | WebRTC (with WebSocket fallback) 21 |
| **Render/Capture Layer** | Distributed Node GPU 9 | Rust Wayland (Smithay/Labwc) 5 | Headless Wayland (gst-wayland-display) 16 | Sunshine/Apollo Host Capture 21 |
| **Multi-User Isolation** | Shared via Blockchain 9 | Single user per container 13 | Headless concurrent multi-session 16 | Single session per stream host 21 |
| **Primary Codecs** | H.264 / H.265 / AV1 9 | H.264 / VP8 / VP9 / JPEG 4 | H.264 / HEVC / AV1 16 | H.264 / H.265 21 |
| **License & Hosting** | Decentralized DPoS 9 | Open-Source (MPL-2.0) 10 | Open-Source (MIT) 16 | Open-Source (GPL-3.0) 31 |

## **2\. Engineering Foundations of Sub-20ms Web Streaming**

To reduce end-to-end latency below the human perception limit of 20 milliseconds, web-based remote rendering architectures must optimize the entire display pipeline, represented mathematically as:  
![][image1]

### **Zero-Copy GPU Memory Buffering**

In conventional virtual desktops, capturing a frame requires copying the rendered output from GPU video RAM (VRAM) back to host system memory (CPU RAM) so that the streaming server can read and process the frame.15 The frame is then copied back to the GPU's hardware-accelerated video encoder (such as Nvidia NVENC, Intel QuickSync, or AMD VCE).22 This dual-crossing of the PCI Express bus introduces up to 15 milliseconds of CPU readback and memory transfer overhead (![][image2]).15  
To eliminate this delay, modern platforms utilize **Zero-Copy Encoding**.13 In Linux environments, this is achieved by sharing DMA-BUF (Direct Memory Access Buffer) pointers across the rendering and encoding APIs.13 When the rendering context (EGL/OpenGL) and the encoding context (VA-API/NVENC) are bound to the identical hardware graphics device node (/dev/dri/renderD128), the raw graphical frame remains entirely within the GPU's VRAM.13  
The compositor passes a direct memory handle of the rendered texture straight to the hardware video encoder, avoiding system RAM copy operations.13 This reduces capture and encoding latency (![][image3]) to under 8 milliseconds.28

### **Damage Tracking and Dynamic Frame Pacing**

Enforcing a fixed 60 FPS or 120 FPS video stream of a static computer desktop is computationally expensive and wastes network bandwidth.5 Conversely, variable frame-rate video streams often cause browser-side decoders to stall or buffer.5  
Selkies resolves this through **Damage Tracking** combined with a proprietary **Paint-Over** algorithm 5:

1. The Rust-based Wayland compositor tracks the precise sub-regions of the screen that undergo pixel changes (known as damage tracking).5  
2. If no desktop updates occur, the system spins the video encoder down to zero frames per second, eliminating CPU and GPU encoding load.5  
3. Because real-time video encoders compress high-motion scenes using a high Constant Rate Factor (CRF), stationary text can remain blurry or pixelated after motion stops.5  
4. To combat this, the "Paint-Over" backend monitors the elapsed frames since the last major motion event.5 Once motion ceases, the server triggers a low-CRF keyframe and a burst of high-quality predictive deltas, forcing the client's screen to instantly snap to native pixel clarity.5  
5. When high motion resumes, the server resumes sending lower-bitrate delta frames.5

### **WebRTC UDP and RTP Real-Time Transport**

Traditional HTTP-based video transport protocols (like HLS or MPEG-DASH) are built on top of TCP, which enforces strict packet ordering.8 If a single network packet is dropped, TCP blocks subsequent data delivery (known as head-of-line blocking) while waiting for retransmission, inflating latency by several seconds.8  
Web-based gaming platforms rely on WebRTC, which runs on top of User Datagram Protocol (UDP) and uses the Real-Time Transport Protocol (RTP).8 WebRTC prioritizes real-time delivery over complete packet reliability.8 If a packet containing video data is lost, the decoder discards the broken frame and continues rendering the next incoming packet, keeping network latency (![][image4]) aligned with the physical round-trip time.8  
To successfully traverse symmetric NATs and stateful firewalls on WAN connections, WebRTC integrates the Interactive Connectivity Establishment (ICE) framework, which leverages Session Traversal Utilities for NAT (STUN) and Traversal Using Relays around NAT (TURN) protocols.8

### **Low-Level Video Decoding via WebCodecs**

Historically, web-based streaming relied on Media Source Extensions (MSE), which forced the browser to buffer video segments before decoding, introducing unacceptable delay.30 Modern web-based clients bypass MSE in favor of the **W3C WebCodecs API**.5  
WebCodecs provides web applications with low-level, direct access to the client device's underlying hardware-accelerated video decoders.5 As raw RTP packets arrive via the WebRTC data pipeline, the JavaScript client extracts the elementary H.264 or H.265 NAL units and feeds them directly into the hardware decoder.5 This reduces browser-side decoding latency (![][image5]) to less than 3 milliseconds.

### **Human Interface Device (HID) Polling Rate Management**

A common bottleneck in browser-based remote play is client-side input handling (![][image6]).3 Modern gaming mice and controllers often operate at polling rates of 1000 Hz or higher.3  
When these high-polling devices are captured in a web browser, the massive influx of input events saturates the Chromium main thread.3 This saturation causes micro-stuttering and increases input processing delay.3  
Lowering the client-side peripheral polling rate to the **125 Hz to 250 Hz range** stabilizes browser performance, reducing perceived input latency without sacrificing responsiveness.3

## **3\. Hardware Profile and Architectural Bottlenecks of the Synology DS225+**

Replicating these low-latency web-rendering technologies on an older network-attached storage device requires working within the physical constraints of the Synology DS225+.

| Hardware Component | Technical Specification | Architectural Impact on Remote Rendering |
| :---- | :---- | :---- |
| **CPU Model** | Intel Celeron J4125 (Gemini Lake) 36 | Low single-threaded performance; susceptible to thermal throttling.38 |
| **CPU Cores / Threads** | 4 Cores / 4 Threads (No Hyper-Threading) 39 | Easily saturated by multiple containerized workloads.40 |
| **CPU Clock Speed** | 2.0 GHz Base / 2.7 GHz Burst 39 | Limits emulator execution to 16-bit and simple 32-bit consoles.41 |
| **Integrated GPU** | Intel UHD Graphics 600 (250 MHz / 750 MHz) 42 | Supports hardware acceleration via VA-API and Intel QuickSync.40 |
| **Onboard RAM** | 2 GB DDR4 Non-ECC (Upgradable to 6 GB) 36 | Crucial bottleneck; requires a physical memory upgrade.36 |
| **Network Interfaces** | 1 x 2.5 GbE RJ-45, 1 x 1 GbE RJ-45 39 | Broad bandwidth overhead; eliminates physical network congestion.37 |
| **Host Operating System** | Synology DiskStation Manager (DSM) 7.x 38 | Volatile root filesystem; customized kernel missing core modules.44 |

### **Graphics Processing Constraints**

The Intel UHD Graphics 600 iGPU embedded within the Celeron J4125 processor does not have the processing power to render modern AAA 3D PC games.38 However, it contains an Intel QuickSync Video (QSV) hardware block.40 This dedicated ASIC is capable of encoding H.264 and H.265 streams in real-time, completely offloading the video compression workload from the weak CPU cores.40  
By passing the host GPU direct rendering node /dev/dri/renderD128 into the container environment, the system can utilize VA-API (Video Acceleration API) for zero-copy web streaming.40

### **Memory Constraints and Operating System Overhead**

The DS225+ ships with **2 GB of onboard non-ECC DDR4 memory**.36 Under standard operating conditions, Synology DSM services consume a significant portion of this memory.36 When launching an accelerated Linux desktop container, the system's memory cache is quickly exhausted.40  
This memory pressure forces the DSM kernel to write active pages to disk swap spaces.40 This storage I/O bottleneck introduces latency spikes into the capture and encoding pipelines.40  
To deploy a self-hosted remote gaming system successfully, the physical memory must be upgraded by installing a **4 GB DDR4 SO-DIMM module** to reach the system's maximum capacity of **6 GB**.36

### **Target Emulation Software Bounds**

Because the Celeron J4125 processor has modest single-threaded performance, game emulation is limited to lighter titles.38 Emulation of 8-bit, 16-bit, and 32-bit systems (such as the Nintendo Entertainment System, Sega Genesis, and Sony PlayStation 1\) runs smoothly at 60 FPS with low latency.41  
Attempting to run resource-heavy 3D systems (like the PlayStation 2 or GameCube) will saturate the CPU.41 This CPU saturation increases frame rendering times, leading to severe input lag.41

## **4\. Re-Engineering the Synology DSM Kernel for Remote Playback**

To successfully run an interactive remote rendering server on Synology DSM, two major OS-level challenges must be resolved.

### **The Virtual Input (uinput) Challenge**

Synology DSM is designed primarily as a storage operating system, and its official kernel lacks the virtual input device driver (uinput) compiled in or loaded.45 The uinput module allows userspace applications to create virtual keyboards, mice, and gamepads, which are necessary to inject client-side inputs back into the operating system.45 Without /dev/uinput, a remote-connected browser can view the video stream but cannot send control inputs.45  
Because Synology does not compile uinput by default, the kernel module must be compiled from source 45:

1. The administrator must spin up an unprivileged Ubuntu container on an external build system or the NAS itself using the Synology Developer Toolchain.45 This toolchain contains the exact GCC compiler version and Linux kernel headers for the DS225+ Gemini Lake architecture.45  
2. Once compiled, the resulting uinput.ko driver file is transferred to a persistent directory on the NAS (e.g., /volume1/docker/drivers/uinput.ko).43  
3. Loading this module requires running insmod /volume1/docker/drivers/uinput.ko with root permissions.43

Note: The official Synology kernel does not enable User Namespaces for security reasons.45 As a result, containers attempting to create unprivileged virtual devices must run in privileged mode or have explicit device cgroup rules applied.25

### **Volatile Device Node Permissions**

By default, Synology DSM restricts access to /dev/dri/card0, /dev/dri/renderD128, and any newly created /dev/uinput nodes to the root user and the videodriver group.44 Docker containers running as unprivileged local users cannot read or write to these nodes, preventing them from utilizing hardware-accelerated video encoding.44  
While manual permissions can be set using chmod, Synology DSM restores default permissions upon every system reboot, which breaks the container's GPU access.44  
To solve both issues permanently, a startup script must be configured using DSM's Task Scheduler 44:

1. Open the **Synology DSM Control Panel** and navigate to the **Task Scheduler**.44  
2. Click **Create** \-\> **Triggered Task** \-\> **User-defined Script**.44  
3. Under the **General** tab, name the task Initialize Remote Playback Kernel Drivers, set the **User** to root, and choose the **Event** as Boot-up.44  
4. Under the **Task Settings** tab, paste the following shell script 43:

Bash  
\#\!/bin/sh

\# Insert the compiled virtual input kernel module  
if \[ \-f /volume1/docker/drivers/uinput.ko \]; then  
    insmod /volume1/docker/drivers/uinput.ko  
fi

\# Wait for kernel initialization  
sleep 2

\# Grant global read and write permissions to the input node  
if \[ \-e /dev/uinput \]; then  
    chmod 666 /dev/uinput  
fi

\# Grant global read and write permissions to the Intel GPU render nodes  
if \[ \-d /dev/dri \]; then  
    chmod 666 /dev/dri/card0  
    chmod 666 /dev/dri/renderD128  
fi

5. Click **OK** to save the task, then select it and click **Run** to execute it immediately.44

## **5\. Deployment Blueprints for Self-Hosted Web-Native Gaming**

With the host kernel configured, the administrator can deploy a containerized streaming host.40 The two primary deployment paths are outlined below.

       \+-----------------------------------------------------------+  
       |                  SYNOLOGY DS225+ (DSM Host)               |  
       |  \+-----------------------------------------------------+  |  
       |  | CONTAINER MANAGER (DOCKER)                          |  |  
       |  |  \+--------------------+      \+--------------------+  |  |  
       |  |  | Webtop Container   |      | Pegasus/RetroArch  |  |  |  
       |  |  | \- Wayland Server   |      | \- Game Emulation   |  |  |  
       |  |  | \- WebRTC Signaling |\<----\>| \- Audio Render     |  |  |  
       |  |  \+--------------------+      \+--------------------+  |  |  
       |  \+------------|---------------------------|------------+  |  
       |               | (Zero-Copy)               |               |  
       |               v                           v               |  
       |       GPU (/dev/dri)             Input (/dev/uinput)      |  
       \+-----------------------------------------------------------+

### **Path A: Selkies-Webtop (General Desktop & Browser Playback)**

This deployment launches an isolated Linux desktop environment accessible through a web browser.14 It uses the modern Wayland compositor (Smithay) and the Labwc window manager, making it a robust option for web-based gaming.13  
Ensure a shared directory /volume1/docker/selkies-gaming is created on the NAS.46 Create a file named docker-compose.yml in this folder and add the following configuration 46:

YAML  
version: "3.8"

services:  
  webtop-selkies:  
    image: lscr.io/linuxserver/webtop:alpine-kde  
    container\_name: selkies\_gaming\_host  
    security\_opt:  
      \- seccomp=unconfined \# Allows modern GUI system calls on older DSM kernels  
    ports:  
      \- "3000:3000/tcp"  \# HTTP interface  
      \- "3001:3001/tcp"  \# HTTPS interface (Required for WebCodecs API)  
    environment:  
      \- PUID=1026        \# Map to your local Synology User ID (UID)  
      \- PGID=100         \# Map to your local Synology Users Group ID (GID)  
      \- TZ=America/New\_York  
      \- PASSWORD=secure\_web\_access\_password \# Password for HTTP Basic Authentication  
      \- PIXELFLUX\_WAYLAND=true          \# Force container to launch in Wayland mode  
      \- AUTO\_GPU=true                    \# Enable auto-detection of graphics drivers  
      \- DRINODE=/dev/dri/renderD128      \# GPU node for EGL 3D rendering  
      \- DRI\_NODE=/dev/dri/renderD128     \# GPU node for VA-API hardware encoding  
      \- SELKIES\_FRAMERATE=60             \# Force frame rate limits  
      \- SELKIES\_ENCODER=vaapi            \# Force hardware-accelerated video encoding  
      \- MESA\_LOADER\_DRIVER\_OVERRIDE=zink \# Resolve Intel UHD 600 compositor rendering bugs  
      \- INTEL\_DEBUG=norbc                \# Resolve screen corruption on Intel Gemini Lake  
    volumes:  
      \- /volume1/docker/selkies-gaming/config:/config  
      \- /volume1/docker/selkies-gaming/roms:/roms:ro \# Read-only access to ROM files  
    devices:  
      \- /dev/dri:/dev/dri                \# Direct passthrough of GPU hardware  
      \- /dev/uinput:/dev/uinput          \# Direct passthrough of the compiled input driver  
    shm\_size: "1gb"                      \# Prevent rendering crashes from memory exhaustion  
    restart: unless-stopped

### **Path B: Headless Multi-User Emulation via Wolf (Games on Whales)**

For a dedicated gaming setup, the Games on Whales (Wolf) architecture allows spinning up isolated game instances on demand.16  
Create the directory /volume1/docker/wolf-gaming and deploy this configuration 19:

YAML  
version: "3.8"

services:  
  wolf-host:  
    image: ghcr.io/games-on-whales/wolf:stable  
    container\_name: wolf\_streaming\_host  
    network\_mode: host                 \# Required for low-overhead Moonlight network discovery  
    environment:  
      \- WOLF\_HTTP\_PORT=8080            \# Port for Web UI management  
      \- WOLF\_HTTPS\_PORT=8443           \# Port for Secure Web UI management  
      \- INTEL\_DEBUG=norbc                \# Prevent allocation corruption on Intel GPUs  
      \- MESA\_LOADER\_DRIVER\_OVERRIDE=zink \# Force stable compositor rendering  
    volumes:  
      \- /volume1/docker/wolf-gaming/config:/etc/wolf:rw  
      \- /var/run/docker.sock:/var/run/docker.sock:rw \# Allows Wolf to spin up game containers on demand  
      \- /dev/:/dev/:rw  
      \- /run/udev:/run/udev:rw  
    device\_cgroup\_rules:  
      \- "c 13:\* rmw"                  \# Permit access to input event nodes  
    devices:  
      \- /dev/dri:/dev/dri                \# GPU passthrough  
      \- /dev/uinput:/dev/uinput          \# Input module mapping  
      \- /dev/uhid:/dev/uhid              \# Virtual USB device mapping  
    restart: unless-stopped

### **Mitigating Intel UHD 600 Driver Bugs**

Intel Gemini Lake architectures running on older kernel versions occasionally experience video buffer allocation issues or screen corruption under Wayland-based compositors.48  
To address these bugs, the blueprints integrate two environment variables 52:

* **MESA\_LOADER\_DRIVER\_OVERRIDE=zink**: This tells Mesa to use OpenGL layered over Vulkan (Zink), which circumvents compositor crashes on Intel integrated chips.52  
* **INTEL\_DEBUG=norbc**: This disables Render Buffer Compression (RBC) on the GPU, resolving frame corruption and garbled visual outputs.52

## **6\. Network Infrastructure, WebRTC Signaling, and WAN Traversal**

Deploying a remote-rendering setup requires configuring the network path between the client's browser and the NAS.8

\+-----------------------------------------------------------------------------------------+  
|                                  WAN / REMOTE CLIENT                                    |  
|                                           |                                             |  
|                                           | (Port 443 / HTTPS)                          |  
|                                           v                                             |  
|                             \+---------------------------+                               |  
|                             |    Reverse Proxy / SSL    |                               |  
|                             | (WebCodecs & PointerLock) |                               |  
|                             \+---------------------------+                               |  
|                                           |                                             |  
|                                           \+---------------+                             |  
|                                           | (Local TCP)   | (Relayed UDP)               |  
|                                           v               v                             |  
|                                     \+-----------+   \+-----------+                       |  
|                                     |  Selkies  |   |  CoTURN   |                       |  
|                                     | Container |   |  Server   |                       |  
|                                     \+-----------+   \+-----------+                       |  
\+-----------------------------------------------------------------------------------------+

### **SSL/TLS and Secure Context Requirements**

Modern web browsers enforce strict security boundaries around low-level APIs like **WebCodecs**, **Pointer Lock** (necessary for mouse capture), and the **HTML5 Gamepad API**.3 These APIs are disabled unless the page is loaded over a secure **HTTPS context** (SSL/TLS).15  
To satisfy this requirement:

1. The administrator should obtain a valid SSL/TLS certificate (e.g., via Let's Encrypt in DSM's settings).  
2. Configure a Reverse Proxy under **Control Panel** \-\> **Login Portal** \-\> **Advanced** \-\> **Reverse Proxy** to route external HTTPS requests (e.g., port 443 or a custom port) to the container's local HTTPS port (3001 for Selkies or 8443 for Wolf).13

### **WAN Traversal via STUN/TURN**

WebRTC attempts to establish a direct peer-to-peer UDP connection between the server (the NAS) and the client (the browser).21 However, if either device is behind a symmetric NAT or a restrictive firewall, the connection will fail.21  
To ensure remote connectivity, a TURN (Traversal Using Relays around NAT) server like CoTURN is required to relay UDP packets 21:

* **Port Forwarding**: The firewall on the router must forward the container's mapped ports.21  
* **Fallback Options**: If a remote network blocks outgoing UDP traffic entirely, CoTURN should be configured to run on **TCP port 443** (masquerading as HTTPS) to bypass strict firewalls.21  
* **WebSockets Fallback**: If WebRTC negotiation still fails, Moonlight-Web-Stream can fall back to streaming over standard WebSockets.21 However, this option incurs higher CPU overhead and increased jitter, making it a last-resort option.5

| Service / Port | Protocol | Scope | Purpose |
| :---- | :---- | :---- | :---- |
| **3000** 13 | TCP | LAN | Standard HTTP administrative access |
| **3001** 13 | TCP | LAN / WAN | Secure HTTPS client access (Required for WebCodecs) 15 |
| **3478** 21 | UDP / TCP | WAN | CoTURN STUN/TURN server signaling |
| **443** 21 | TCP | WAN | Secure fallback relay port for CoTURN |
| **47984 \- 47990** 54 | TCP | LAN / WAN | Moonlight/Sunshine GameStream compatibility ports 28 |
| **48010** 54 | TCP / UDP | LAN / WAN | Sunshine RTSP streaming control port 28 |
| **47998 \- 48000** 54 | UDP | LAN / WAN | Sunshine real-time audio and video streams 28 |

## **7\. Performance Tuning and Actionable Recommendations**

To maximize rendering performance and minimize stream latency on the DS225+, the system administrator should implement the following host and container-level optimizations:

### **Emulation Engine Configurations (RetroArch / Pegasus)**

* **Verify Video Driver**: Set the video driver to gl or vulkan in the emulation backend.13 This ensures game frames are rendered directly on the Intel UHD 600 iGPU rather than relying on the weak Celeron CPU.40  
* **Select Audio Driver**: Configure the emulation audio driver to use pulseaudio or alsa.13 This matches the sound system of the Selkies container, reducing audio sync delay (![][image7]).13  
* **Avoid Heavy Shaders**: Disable post-processing CRT shaders, as they can quickly overwhelm the Intel UHD 600's processing capacity and cause frame drop stutters.41

### **Memory Allocation Safeguards**

* **Limit System Memory Pressure**: Within the DSM Control Panel, shut down unused native applications (such as Synology Drive, media indexing servers, or active antivirus scanners).40 This keeps physical RAM free for the game render and encoding pipelines, preventing system disk-swapping.40

### **Client Browser Calibration**

* **Confirm Hardware Acceleration**: Ensure hardware-accelerated video decoding is enabled on the client-side browser.3 If the client browser relies on software decoding, the video decode phase (![][image5]) will spike, causing dropped frames and lag.3  
* **Disable High-Polling Inputs**: If the remote session experiences stuttering when moving the mouse, lower the client peripheral polling rate to **125 Hz**.3 This reduces the browser's input processing load and stabilizes frame pacing.3

#### **Works cited**

1. Low-latency Video Streaming \- IEEE Xplore, accessed June 10, 2026, [https://ieeexplore.ieee.org/iel8/9739/5451756/11501921.pdf](https://ieeexplore.ieee.org/iel8/9739/5451756/11501921.pdf)  
2. Low Latency Gaming Infrastructure: A Network Optimization Guide \- Netrality Data Centers, accessed June 10, 2026, [https://netrality.com/blog/data-center-low-latency-gaming-infrastructure/](https://netrality.com/blog/data-center-low-latency-gaming-infrastructure/)  
3. Browser-Based Cloud Gaming on Smart Displays: Input, Codec & \- KTC, accessed June 10, 2026, [https://us.ktcplay.com/blogs/technology-hub/browser-based-cloud-gaming-on-smart-displays](https://us.ktcplay.com/blogs/technology-hub/browser-based-cloud-gaming-on-smart-displays)  
4. shylabs/selkies-gstreamer: Open-Source Low-Latency Linux WebRTC HTML5 Remote Desktop / GStreamer WebRTC Components of Selkies \- GitHub, accessed June 10, 2026, [https://github.com/shylabs/selkies-gstreamer](https://github.com/shylabs/selkies-gstreamer)  
5. Webtop 4.1: X11 is dead and what is Selkies, anyway? | LinuxServer.io, accessed June 10, 2026, [https://www.linuxserver.io/blog/webtop-4-1-x11-is-dead-and-what-is-selkies-anyway](https://www.linuxserver.io/blog/webtop-4-1-x11-is-dead-and-what-is-selkies-anyway)  
6. What about a WebAssembly port? · Issue \#446 · moonlight-stream/moonlight-chrome \- GitHub, accessed June 10, 2026, [https://github.com/moonlight-stream/moonlight-chrome/issues/446](https://github.com/moonlight-stream/moonlight-chrome/issues/446)  
7. Deploy Real-Time Game Streaming at \~300ms WebRTC Latency \- Ant Media Server, accessed June 10, 2026, [https://antmedia.io/solutions/video-game-streaming/](https://antmedia.io/solutions/video-game-streaming/)  
8. Low-Latency WebRTC Streaming: Real-Time Video at Scale \- Flussonic, accessed June 10, 2026, [https://flussonic.com/blog/article/low-latency-webrtc-streaming](https://flussonic.com/blog/article/low-latency-webrtc-streaming)  
9. What Is DeepLink Protocol? Decentralized AI Cloud Gaming Explained | Gate Learn, accessed June 10, 2026, [https://www.gate.com/learn/articles/deep-link-the-ultimate-decentralized-ai-cloud-gaming-protocol/4899](https://www.gate.com/learn/articles/deep-link-the-ultimate-decentralized-ai-cloud-gaming-protocol/4899)  
10. Selkies, accessed June 10, 2026, [https://selkies-project.github.io/selkies/](https://selkies-project.github.io/selkies/)  
11. Selkies-GStreamer download | SourceForge.net, accessed June 10, 2026, [https://sourceforge.net/projects/selkies-gstreamer.mirror/](https://sourceforge.net/projects/selkies-gstreamer.mirror/)  
12. AIP\_197 OpMV / OpMV\_SELKIES / Selkies Gstreamer \- NRP GitLab, accessed June 10, 2026, [https://gitlab.nrp-nautilus.io/aip\_197-opmv/opmv\_selkies/selkies-gstreamer/-/tree/master](https://gitlab.nrp-nautilus.io/aip_197-opmv/opmv_selkies/selkies-gstreamer/-/tree/master)  
13. baseimage-selkies \- LinuxServer.io, accessed June 10, 2026, [https://docs.linuxserver.io/images/docker-baseimage-selkies/](https://docs.linuxserver.io/images/docker-baseimage-selkies/)  
14. docker-baseimage-selkies \- LinuxServer.io \- GitLab, accessed June 10, 2026, [https://gitlab.com/Linuxserver.io/docker-baseimage-selkies/-/tree/debianbookworm-79f8300e-ls22?ref\_type=tags](https://gitlab.com/Linuxserver.io/docker-baseimage-selkies/-/tree/debianbookworm-79f8300e-ls22?ref_type=tags)  
15. webtop \- LinuxServer.io, accessed June 10, 2026, [https://docs.linuxserver.io/images/docker-webtop/](https://docs.linuxserver.io/images/docker-webtop/)  
16. Games on Whales, accessed June 10, 2026, [https://games-on-whales.github.io/](https://games-on-whales.github.io/)  
17. Games on Whales \- Stream multiple desktops and games from a single host \- Reddit, accessed June 10, 2026, [https://www.reddit.com/r/selfhosted/comments/1e0nrxo/games\_on\_whales\_stream\_multiple\_desktops\_and/](https://www.reddit.com/r/selfhosted/comments/1e0nrxo/games_on_whales_stream_multiple_desktops_and/)  
18. games-on-whales/wolf-den: A web UI for managing Wolf \- GitHub, accessed June 10, 2026, [https://github.com/games-on-whales/wolf-den](https://github.com/games-on-whales/wolf-den)  
19. A plugin for running Games on Whales on Unraid \- GitHub, accessed June 10, 2026, [https://github.com/games-on-whales/unraid-plugin](https://github.com/games-on-whales/unraid-plugin)  
20. Moonlight Web Client, accessed June 10, 2026, [https://ideas.moonlight-stream.org/posts/111/moonlight-web-client](https://ideas.moonlight-stream.org/posts/111/moonlight-web-client)  
21. GitHub \- MrCreativ3001/moonlight-web-stream: This is a web server ..., accessed June 10, 2026, [https://github.com/MrCreativ3001/moonlight-web-stream](https://github.com/MrCreativ3001/moonlight-web-stream)  
22. Sunshine | LizardByte, accessed June 10, 2026, [https://app.lizardbyte.dev/Sunshine/](https://app.lizardbyte.dev/Sunshine/)  
23. moonlight-web-stream stability : r/MoonlightStreaming \- Reddit, accessed June 10, 2026, [https://www.reddit.com/r/MoonlightStreaming/comments/1rgjl37/moonlightwebstream\_stability/](https://www.reddit.com/r/MoonlightStreaming/comments/1rgjl37/moonlightwebstream_stability/)  
24. Finally a moonlight web client\! : r/MoonlightStreaming \- Reddit, accessed June 10, 2026, [https://www.reddit.com/r/MoonlightStreaming/comments/1o14itg/finally\_a\_moonlight\_web\_client/](https://www.reddit.com/r/MoonlightStreaming/comments/1o14itg/finally_a_moonlight_web_client/)  
25. Quickstart \- Games on Whales, accessed June 10, 2026, [https://games-on-whales.github.io/wolf/stable/user/quickstart.html](https://games-on-whales.github.io/wolf/stable/user/quickstart.html)  
26. Can multiple clients play different games? · LizardByte · Discussion \#262 \- GitHub, accessed June 10, 2026, [https://github.com/orgs/LizardByte/discussions/262](https://github.com/orgs/LizardByte/discussions/262)  
27. GitHub \- linuxserver/docker-baseimage-selkies: Base Images for remote web based Linux desktops using Selkies for many popular distros., accessed June 10, 2026, [https://github.com/linuxserver/docker-baseimage-selkies](https://github.com/linuxserver/docker-baseimage-selkies)  
28. Sunshine \+ Moonlight Remote Gaming | Guides \- Clore.ai, accessed June 10, 2026, [https://docs.clore.ai/guides/gaming-and-streaming/sunshine-moonlight](https://docs.clore.ai/guides/gaming-and-streaming/sunshine-moonlight)  
29. Releasing Wolf: Stream virtual desktops and games in Docker : r/homelab \- Reddit, accessed June 10, 2026, [https://www.reddit.com/r/homelab/comments/14csdic/releasing\_wolf\_stream\_virtual\_desktops\_and\_games/](https://www.reddit.com/r/homelab/comments/14csdic/releasing_wolf_stream_virtual_desktops_and_games/)  
30. Game Streaming on Tizen TV with Wasm \- Samsung Developer, accessed June 10, 2026, [https://developer.samsung.com/smarttv/develop/extension-libraries/webassembly/game-streaming-on-tizen-tv-with-wasm.html](https://developer.samsung.com/smarttv/develop/extension-libraries/webassembly/game-streaming-on-tizen-tv-with-wasm.html)  
31. package.json \- MrCreativ3001/moonlight-web-stream \- GitHub, accessed June 10, 2026, [https://github.com/MrCreativ3001/moonlight-web-stream/blob/master/package.json](https://github.com/MrCreativ3001/moonlight-web-stream/blob/master/package.json)  
32. Parsec (software) \- Grokipedia, accessed June 10, 2026, [https://grokipedia.com/page/Parsec\_(software)](https://grokipedia.com/page/Parsec_\(software\))  
33. Low Latency Streaming & Real-Time Video \- Wowza, accessed June 10, 2026, [https://www.wowza.com/low-latency](https://www.wowza.com/low-latency)  
34. DASH-IF Report: DASH and WebRTC-Based Streaming, accessed June 10, 2026, [https://dashif.org/webRTC/report.html](https://dashif.org/webRTC/report.html)  
35. selkies/docs/start.md at main \- GitHub, accessed June 10, 2026, [https://github.com/selkies-project/selkies-gstreamer/blob/main/docs/start.md](https://github.com/selkies-project/selkies-gstreamer/blob/main/docs/start.md)  
36. Synology DiskStation DS225+ 2-Bay Diskless NAS \- Micro Center, accessed June 10, 2026, [https://www.microcenter.com/product/698129/synology-diskstation-ds225-2-bay-diskless-nas](https://www.microcenter.com/product/698129/synology-diskstation-ds225-2-bay-diskless-nas)  
37. Synology Disk Station DS225+ \- NAS server \- CDW, accessed June 10, 2026, [https://www.cdw.com/product/synology-disk-station-ds225-nas-server/8461432](https://www.cdw.com/product/synology-disk-station-ds225-nas-server/8461432)  
38. Synology DiskStation DS225+ 2-Bay NAS Enclosure \- B\&H, accessed June 10, 2026, [https://www.bhphotovideo.com/c/product/1908413-REG/synology\_diskstation\_ds225\_2\_bay\_nas.html](https://www.bhphotovideo.com/c/product/1908413-REG/synology_diskstation_ds225_2_bay_nas.html)  
39. DiskStation DS225+ | Synology Inc., accessed June 10, 2026, [https://www.synology.com/en-sg/products/DS225+](https://www.synology.com/en-sg/products/DS225+)  
40. Running Jellyfin on a NAS in 2026: Synology, TrueNAS, and Unraid Complete Guide, accessed June 10, 2026, [https://jellywatch.app/blog/jellyfin-nas-synology-truenas-unraid-guide-2026](https://jellywatch.app/blog/jellyfin-nas-synology-truenas-unraid-guide-2026)  
41. Self host a retro game emulator? : r/selfhosted \- Reddit, accessed June 10, 2026, [https://www.reddit.com/r/selfhosted/comments/1shoct4/self\_host\_a\_retro\_game\_emulator/](https://www.reddit.com/r/selfhosted/comments/1shoct4/self_host_a_retro_game_emulator/)  
42. Which Hardware for Proxmox and docker? : r/HomeServer \- Reddit, accessed June 10, 2026, [https://www.reddit.com/r/HomeServer/comments/1c244t9/which\_hardware\_for\_proxmox\_and\_docker/](https://www.reddit.com/r/HomeServer/comments/1c244t9/which_hardware_for_proxmox_and_docker/)  
43. \[Discovery\] Unlocking Native Hardware Transcoding on Synology 25-Series (J4125 Models)\!, accessed June 10, 2026, [https://community.synology.com/enu/forum/1/post/194638?reply=530999](https://community.synology.com/enu/forum/1/post/194638?reply=530999)  
44. Hardware Transcoding on Synology Docker without Privileged Mode, accessed June 10, 2026, [https://ryanbritton.com/2022/05/hardware-transcoding-on-synology-docker-without-privileged-mode/](https://ryanbritton.com/2022/05/hardware-transcoding-on-synology-docker-without-privileged-mode/)  
45. Does anyone have a lightweight VM image of this? · Issue \#196 \- GitHub, accessed June 10, 2026, [https://github.com/Steam-Headless/docker-steam-headless/issues/196](https://github.com/Steam-Headless/docker-steam-headless/issues/196)  
46. Best transcoding settings for Synology DS920+ : r/jellyfin \- Reddit, accessed June 10, 2026, [https://www.reddit.com/r/jellyfin/comments/r5pur8/best\_transcoding\_settings\_for\_synology\_ds920/](https://www.reddit.com/r/jellyfin/comments/r5pur8/best_transcoding_settings_for_synology_ds920/)  
47. Retro-gaming/couch-gaming homelab ultimate end game found? (Wolf from GoW) \- Reddit, accessed June 10, 2026, [https://www.reddit.com/r/selfhosted/comments/1lgbgte/retrogamingcouchgaming\_homelab\_ultimate\_end\_game/](https://www.reddit.com/r/selfhosted/comments/1lgbgte/retrogamingcouchgaming_homelab_ultimate_end_game/)  
48. Test on Windows with WSL2 · Issue \#13 · games-on-whales/gow \- GitHub, accessed June 10, 2026, [https://github.com/games-on-whales/gow/issues/13](https://github.com/games-on-whales/gow/issues/13)  
49. Plex on Docker on Synology: enabling Hardware Transcoding | by Nick \- Medium, accessed June 10, 2026, [https://medium.com/@MrNick4B/plex-on-docker-on-synology-enabling-hardware-transcoding-fa017190cad7](https://medium.com/@MrNick4B/plex-on-docker-on-synology-enabling-hardware-transcoding-fa017190cad7)  
50. GitHub \- linuxserver/docker-webtop: Ubuntu, Alpine, Arch, and Fedora based Webtop images, Linux in a web browser supporting popular desktop environments., accessed June 10, 2026, [https://github.com/linuxserver/docker-webtop](https://github.com/linuxserver/docker-webtop)  
51. How I got Plex hardware transcoding working with docker on my DS918+ \- Reddit, accessed June 10, 2026, [https://www.reddit.com/r/synology/comments/e4r1bu/how\_i\_got\_plex\_hardware\_transcoding\_working\_with/](https://www.reddit.com/r/synology/comments/e4r1bu/how_i_got_plex_hardware_transcoding_working_with/)  
52. Corrupted stream with Intel iGPU \#50 \- games-on-whales/wolf \- GitHub, accessed June 10, 2026, [https://github.com/games-on-whales/wolf/issues/50](https://github.com/games-on-whales/wolf/issues/50)  
53. Self-hosted Retro Cloud Gaming : r/emulation \- Reddit, accessed June 10, 2026, [https://www.reddit.com/r/emulation/comments/1kc1gj6/selfhosted\_retro\_cloud\_gaming/](https://www.reddit.com/r/emulation/comments/1kc1gj6/selfhosted_retro_cloud_gaming/)  
54. Docker \- Sunshine documentation, accessed June 10, 2026, [https://docs.lizardbyte.dev/projects/sunshine/v0.16.0/about/docker.html](https://docs.lizardbyte.dev/projects/sunshine/v0.16.0/about/docker.html)

[image1]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAmwAAAA2CAYAAAB6H8WdAAAG+ElEQVR4Xu3ca8gtUxzH8eV+DwlFOFEup1BILumUQkheuCXpnDdSJC9cQjhyKZdCXvCCJO/wglyiXBIh93sInbygUHK/39bPrH/P//zNM3tmzn6evWc/30+tZtZ/9t5n/WetM7P2zDw7JQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgKH5Kpd/SvkubBuCobdfZiGHNr5Ps5vnLOdWx4/Zv3K5ee3Ng7bU+hLAgOjAtG0MDsi0tf/9GGhh2nJoY5bzPD4GWhhKbnXWj4EWbLI27WZ5nAJYYnRwGrJpa3+f9vR5z6R1bfO5qft7JuWiGBhhSLnV2TQGWlC+x8XgFOraL0PvSwAzbOgHp2lrf5/29HnPpHVt85e5vByDU6rrhE25dd0f02TLGGhhKPl2beeQximAJeS+XP6IwUVyay5rRpRRJtn++XQ9QUxjDm10zVOv7zMxmISuEzblNsQ+NFvFwAhDGrOzPE4BLCE6OC3UbY3ncjkqBsesqf1/x8ACOSgUtcnXl8+9tFZTDtNkh9Scp0qTuhPnkTEwJs+mbvs05nFbqPfpw4XKrclPMdDA57ci1Nv0Zcw32jfV93lX9+bySgw2mNZxqit3ANBb3cHphxhYB4sxYYvG2X55MgZGqGtTk7rXr2sOD8TAAqhr93z2S/WvvzsGxmjUhKJJlyts48jt8Bjo6bIYaKnrFba6fOvGbN3r+ugyYYu6tGEcfTmfE2IAANraIP3/4PRRLjeUdW1T2avU78jlglyuCNvtM/Tt/qFcdip1WcgJW5v221Lf9vVcyjcu9kguT+TyVol9WOK2XVaX9fjvNOny2lE5HJLL7bn8WOr35HJ+qq4gieXxdVm3mG+zlifl8liIHevqv+TyfC5Xl3obsd1Nvs3l7RBTnkZXY2/J5d1S12fflMvnqXoIXDbO5alcfi910Ync/xXgq6kag/qZCZuw9cmty4StKTcbU5aLUb5XpSpfPfAf+0vlg7K07bJRLnfm8nOpK35Nqvp251wucfEu/dNlwlY3ZndJc2N2vVx+S9UY9a97OlX9oO1i+0WfJxrjupq2YamrD+7K5Y00N2FbWeJd+jK2tUlTX16aqs9SHtaXOp78Wtatr/1xRiyPG11MY9Ly0L7SX9vGfxcA/qMDoB3Un0nVpCUe5Fe7dU0ITivrdlLw20UnE/GfcbRbH6c27X/PrVubH3exh8tSJxp7ny1tm4+11fb1bXKw9U3K0vbxm2UpdW2NV9g0YRP/2fbTFdo3dhLVyaOtrnl+nKqTeMxTPylxdlm/tiw/KUuJfWMn+LifNNa2djFN2Prm1nbC5nMb1YdycarPN+7LmPOOoS4vlaUmqUb5aqz4/dBG2wmbcrT8tP6Cq5u69Rh70dVFxxdjr9UE3tiE7YuyVF9uUdZHift2PqPGqfh1mzSLTcZsux1nlKflsaos68Zk2zYCQK0ry/KsVB1QTi71C3PZ3G23E79+cFL8wecYt77Y/DdWm7D4yY2t63ZUPLE8WpY+1lbX1zf5M9Tts19zsboJ24Np7d8SO7UsfduWlaWunPYxrjw1GTklxHR1ycS+MfFEen1a+/fElH/f3NpO2Nrw7dTJui5fe97SJlrnpeqq1Zlp7vfAVPefZWPjHhezLya6gtNF2wlbG7FfYkz8ZEfie/TQ/+UuZpNSfzW1rfhvr4vYzshi9n9Sf5hheawqy7oxWfdZANCaJmqiiZlOHLodJWvK0rZfl6oTzcpS18FHt2hEt90m5R23blcH/UTs9bL8LFW3O6TuBNP1YGpXgMbB/m2drLWPra4T3ull3fLQJNry0G0b9Ys5oyx9Lru7dU3CZR8XG2WceaoPvE/del2fiL+larfadLtYtL9OLOt9chsn3257xizma7fY7MqL2Pt0my7GtO/t6rVuIxr7EqWrRJOiNmos2rrcX5aifjsilz1LXf2j44uxyau/hWxXlO3z1Jdtr7CNc5z6vtw/l+3K+jlladvtOKMvuZaHv2IYx2Qc2wDQ2d6hflio++26umG37oZA34IPiMFUPXi8PJdtXKzPD4uOi56/89Q+T3lslkafwJSD/kLOTwq8A2Ngkdmzkk3ir8+rj2LemgzIri426dzqrAj1PULdrrbFnG2iM830vKEmbYemudv4uooX+8Ff2dO4XObqYn/R6XMe1x9ojMtuMVBDeejZ3u1dbNryAICpdHCqHhIeOstjWYgDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABgYf0LqZ7SHBXpb4sAAAAASUVORK5CYII=>

[image2]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAD4AAAAZCAYAAABpaJ3KAAACAElEQVR4Xu2XvUuVcRTHTy+TYY4tCuEghktkOhQN5qROJm5SRGObODQ0XIqIloSGdFC54D/gIrgoUkuDgUENjRUUYS9kVPai9f1yzg/PPTeuDfcaPM/zgS/3nO957nN/53fP776IFBQU5Ik5aBP67fQJuusvyjKp6VxxQLTpx7GQda6KNj4YC1nnreRwzEkuzzdh04+imXX2Ot/no5EVNqT2mPM7vRHcicZ+U+t8X4f6olkndqKxnxwSbfpJLIA2qd6QF9B96AF0xrwyNA4tQKvmkbSh96Ali7tCzW+6j3ss3rL8u+UDomstmX8JWoYeQjfM+ycmRW84HPxp89ed91z084Bcg25b/Bo6ZvE7qZyQuHE+jzXivW7ZbZz8gG5CndBZ0dfc635VzIveaFt05PzuM/8FfYNa0xOsdtDlnhFoBfoJXXR+XAzzURdHvHdKKhtn3OFy9sBJeGViL75eN7goHo0I/X6L10THz9c8zC+4mAzZo/fIadHGEmz8uMunoGcubxg8S9zlBEe8RSoX+xW6DC1aztphi5ssT6T41l88Mis6eQlOU7vLib/+BHTE5XWlLHoEXjpvBvoi+rP3qOhRabYaF1YS3bTP5iXGoI/QhPN6oTeif5ZOij6fDXND34tezw1J8HU+QE+hK87/78RRzwV899j4uVgoKChoKH8A5uiPZuGGK3kAAAAASUVORK5CYII=>

[image3]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAJEAAAAZCAYAAAAxO8yWAAADiUlEQVR4Xu2ZS6iNURTHl0cGhJKYUELyjLwGZICRR8prJo6YmYkSBjdCKIrCAN0wMvIsAyQm8giFGHnl/X6/H+tvrd23znLuPee79zvuPX37V//O2muf/Z291rf23t85hygSiUQikUgk4tnLesf6bfSWtcW+KVKWmEdKAo80j9zmsQ1J4Jd9R47I4sbnOo9LSIKf6jtyRBZFlOs8PqVskljLZBF/rvOY23PckEX8uc4jAj/vnTkji5uf2zyWO8cneUeN04M1uoSQA++DBsuwsrTWPA4jOWYv+I4seU6Nr0L81lENNnrHf6I/a0YJIQfeB02UYWVpqTxWAuKoahE1do6vpsqTmJZf3tHCNJSDSmmpPFbCdKpiEbUjCfya72B6079JucfawTrLGqe+etZS1iHWGfWBkNRtrBNqD3F9NvHWHqP2F21/1fYUkrnWqX8B6xTrHGuN+pqKjzUNafOI/G0liW+o+kL8m1kHWK/UH9jOOknSf9D4H5Dk4wYl1wLLWTdJ7skmKi6iLPP2NxBMfKbz71L/VeO7TXLugxWsDWo/YvVU+wUVrzifPNv2fcD6RlFSROAbay1rIGs8yWeWu14amjM+TR5xjB82bR9DB7VxkxepXWDdV7sb64naWNT91AYYj4LG8XXH+BdTUkSZ5W0/yU35SXKs4EJBaP9gfWb1CgO0r61pW2azTrO+s+Ybv58g2nON7bG+kVRcRLAHmDZiwA6FlQghFtufllLzKUdT84jnpzDvhm7ocZLFCnB9HIkeP2dcF2Pe62ugQEkRZZ23VGDCqHIP/JPVvkSyVdo+C9qzjA2m6av1AXwzQrABFFEf095JsoVnhZ9rtcDnhIXksXM4QkkhfKLkCLf4OX9grSdZzLboCqyLamedt1Rge0UVB3CMdaXiQBDsQpJVBNDXXu2O2g4Ee10JH9hDspIDSExf0wb2/YNYnUw7LaUWSDUYTnIMBWxObTzHWCvVnkDFucAxCfCIgb4AxuP/uzmsh8aP4/aKaWeZt9TUk2zP4XwGu1kfSX6L6EKyjXfWPky2jqQAscVa5rFes5YZ31jWY5I/MEeQjEfxoDhfkrwfxRXA5+AB9Dolzw+1AL6UIDYUU3iefEPyTIlcHiWJC1ql/dixcfTcYnVXH9hHcj+eUfHjBh6s75LkDV988Hnhj+GaypvfbiORVGBXQRHZ7TYSiUQikUiktfAH88gpUwaAb+EAAAAASUVORK5CYII=>

[image4]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEIAAAAZCAYAAACFHfjcAAACIklEQVR4Xu2Wz0tVQRTHjwVSf4EktmobtG9noovARWCraFWLoNy5qEwX2iaSWipEv6NctNHSlW5atQkSN4KLEHHhj0KDSqK079dzTu+8oWcv3nsQ3PnAlzfzPXfenTl35twrkslkMtXzAPoM7QZtQXfiRUXCk1BomkST8C4NFI3Look4nQaKxqrkY7FHrg8Gk/A2NYvG3+rDqdT4z+iCvoh+BtTEuux/LPhNUQs7qdEABqQOidivPtyA2lPzH6n03/XkmtSYiIOiE51LA+ColC/CE3YbegZ9CjHyBroLbUPHoUNSGkO9gA6H/qXQvhjaT0UZhe5BT0SfOOGCec0wNAWtmH8Vemht/5/71q8KTpyDziT+mPnvE59es7VnoQvWvgVNWJvwuj+1nUrxPvu9IpoAZxrqtvZ10WSTm/bLRPD6A9C8eVXBrH+HfoqeYc8ixf4P6BvU5gOMOGk+EU7AfdaaZVOlhTr0jkC9ovPgAs4l8c7QZ0FnQSS85/MQc++V6Dh+JTecuKhJKU/E2RCL+JjHwWMC+Lpeg86LbuNYlDmmJ/S5U/hwCO/5qBT67Y1DHaIPsOHERLwW3abkBLQUYn7OiY/x7ezQPxnaceFMzkzofxB9TZJ+KT82ZFC0dpFFaCjE6s4mtCG6RbkNWSwpToxwUVwQE9JiHnkJLUCtwSPxyaWFl7CAMnlfoWPm8V5+Xx6p1BsRvf6jlI5SJpPJZGrhF4qbneLk9Cg5AAAAAElFTkSuQmCC>

[image5]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADkAAAAZCAYAAACLtIazAAABoklEQVR4Xu2XuUoEQRCGyyPyBUw0MBfMRMw0VEQMfAEDDQxMDYxMxEQzMVARfAF9AAMVwftCBMFgPBDESBMPvP6f7nZqW3cWhgZl6A8+tqdqhqre7dplRSKRyH9mAT7CT+UDnNI3FQW3wcJSJWaD+36iSAyL2WSXnygSd1Lwo0oKP4+EG9zyg0Wi0jx2+gEwKtnPhCBojXvJPqr8zfyNAwnUQAbBamTN4xjs8IOWPQnUQAZBatSI2eCxnwCN8nPzu3AZXsAzKW1gHU7DZ9is4pdwxubbbawN7sBxeGhjjjw1MuED3EifF5+18SMVY/EhdX0jaQOTcEXl3JtzLmbmCWdsAtapPGmF23adp0ZZluArfIcfkh5Zyus3+AQb3AM2p0kkbYA5zva11d3L12q7dszBTS+m79ckUrlGUPyGE9ht18z1p6lvGOdIaObhqRcr96YkUrlGUE7giLrmP5deu24RM3sOnhSyqtbkFtZK6acwADfsOk+N4KyJaYizlohptsfm+KXCazZSb2NkUczRv1KxJvgi5t5BFSd5akQikcjf8wUYrIo+vNmeNgAAAABJRU5ErkJggg==>

[image6]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADEAAAAZCAYAAACYY8ZHAAABmklEQVR4Xu2XuUoEQRCGS0x8AgNR8AH0CYw0EjMR1FjMfAHvN1iNBCNBDEwMxAM0MlVE0URFUDAw8MIr8MDrL6ob/mmcWVl2cRvmg5/tqr9numume2ZWJCcnJ4s56An6Jj1CU9wpFnwB0VIjVsBeaMTEkFgRXaERE1cS+VJSot8PihawHSZjoth+6HC/A9ADG9XEjWQvJX1nKC1QgY0K8RUm/kLWfhiH2sNkhUmbSyq1YgcdhgZokuQJudgT126FdqBLsWWpjDhvVewu70IHzlP4POuuPQzVkadadH2KMi12QHeQn3V5Hlzhos7FJu9hbxLaolhfohsUc18tVovwsJfJAvQOfYqtQb4CGn9AL1CjP8DBA5xC/RSzp3djheJOSfrc1n4lFVEqPMAx1EMxezopLqJN0otYEyva4715ypUVHvwM6qM4LIK/wy7k94n69kQQK6+UKxv6qL2D3sTugrbvoV7n3ULPrq8WsQldi+2bQZf3zED70JHYXwGd+JjzlsQeHA0u/jdGJbmcoqMeWha7ms1JKyenKvkBIkl7RGE3pwMAAAAASUVORK5CYII=>

[image7]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADcAAAAZCAYAAACVfbYAAAABo0lEQVR4Xu2WuUoEQRCGS30NfQgfQRNBETFSBE0NDEwUvDKNNdRIRMFAExNjERPBW8EDFQY8QMQ78D7+oquZ3lpmDJxRbPqHj6mq7q6Zf7d7Z4mCgoL+UuPgHnw63IFhd9J/lzXmnUrIGFvTAz6og4y5Wj3ggy7I0y3J8va8sdjYsi76oO/OW7UuZKgeSr/3j3VJ6VuS33l5ap1yNJd23gZAlS5mrFXKyVwZGWNbegCqoELTHL+DY1V/BN3glcz7slnGZ8EGWKDi87wC5sAR2KVCc7pfL5l+g2AenMVT0zVCZmGjqo9JfVPVralRufLftkqJa8ChxG1U/MFYsbF2Jz+l2FxSvz7wJPGQXBM1BV7IfBMfFG9NhvM3Mp9guV0g0tuX8xMHO94C9u0kp65jVkSxuaR+/MMzLXFu0g+mc6smsOPk2lypk0egTuKkfmxuQhezlr75DOhy8gO5toI9p+6u2wadTs5bsUHipH79YNKpZ65bcAUeVJ1v/AzOJecteUNmLhvh7c0xr7daBEtkHj4iY75exnQ/zq8FPkpBQUFBv6Mve8mGkYeYlXkAAAAASUVORK5CYII=>