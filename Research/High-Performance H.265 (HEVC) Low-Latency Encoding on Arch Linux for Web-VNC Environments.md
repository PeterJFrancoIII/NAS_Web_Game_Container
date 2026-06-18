# **High-Performance H.265 (HEVC) Low-Latency Encoding on Arch Linux for Web-VNC Environments**

To achieve sub-frame, real-time desktop streaming within a browser-based VNC interface, the standard RFB pixel-differencing protocol must be bypassed in favor of a hardware-accelerated H.265 (HEVC) video stream. This guide provides a detailed technical blueprint to implement and optimize this hardware-accelerated video pipeline on Arch Linux.

## **1\. Driver & Acceleration API Selection**

Choosing the correct hardware acceleration API depends heavily on your GPU architecture. The goal is to minimize host-to-device memory copy overhead and maximize hardware encoding throughput.

### **API Evaluation**

* **NVIDIA (NVENC):** Represents the gold standard for low-latency streaming. NVENC operates on dedicated, independent silicon on the GPU, completely bypassing the graphics rendering pipeline. It features highly optimized proprietary driver support on Arch Linux and provides specialized low-latency rate control algorithms (llhq and llhp) that minimize frame-buffering.  
* **Intel (Quick Sync Video / QSV & VA-API):** Highly efficient. Intel's open-source intel-media-driver (iHD) provides low-overhead execution via VA-API and QSV. On modern Intel architectures, QSV can perform asynchronous, zero-copy memory transfers directly to VA-API surfaces.  
* **AMD (VA-API / AMF):** AMD's proprietary AMF is complex to configure on Arch Linux. Instead, Mesa’s open-source VA-API driver (radeonsi) is highly recommended. It provides a lightweight execution layer that maps directly to AMD’s Video Core Next (VCN) hardware engine.

### **Driver Package, Module, and Environment Variable Matrix**

To configure the hardware acceleration stack on Arch Linux, install the respective packages and apply the following system configurations:

| Architecture | Required Pacman Packages | Kernel Modules | Environment Variables | User Group Membership |
| :---- | :---- | :---- | :---- | :---- |
| **Intel (QSV / VA-API)** | intel-media-driver, libva, onevpl-intel-gpu, libmfx | i915 or xe | LIBVA\_DRIVER\_NAME=iHD | video, render |
| **NVIDIA (NVENC)** | nvidia, nvidia-utils, libva-nvidia-driver (optional) | nvidia, nvidia\_modeset, nvidia\_uvm, nvidia\_drm | \_\_NV\_PRIME\_RENDER\_OFFLOAD=1 | video, render |
| **AMD (VA-API)** | mesa, libva-mesa-driver, libva | amdgpu | LIBVA\_DRIVER\_NAME=radeonsi | video, render |

### **Granting Hardware Access**

For containers or non-root users to interface directly with the GPU hardware, they must be added to the render and video groups:

Bash  
sudo usermod \-aG video,render ${USER}

## **2\. Capture & Encoding Pipeline**

### **The Bottleneck of Traditional Capture**

Standard desktop capture utilities like x11grab or GStreamer's ximagesrc utilize synchronous system calls (such as XGetShmImage). These calls pull frames from GPU memory (VRAM) down to system RAM (CPU) for color-space conversion, only to upload them back to the GPU for hardware encoding. This round-trip copies gigabytes of raw pixel data over the PCIe bus, introducing 4 ms to 10 ms of unnecessary latency and consuming substantial CPU cycles.

### **Zero-Copy Capture via KMS/GBM (DMA-BUF)**

To achieve ultra-low latency, the pipeline must employ **zero-copy buffer sharing**. By utilizing the Kernel Mode Setting (KMS) grabber (kmsgrab), we can share the physical graphics framebuffer directly with the hardware encoder via Linux **DMA-BUFs**. The frame buffer remains entirely inside VRAM throughout the capture, scaling, and encoding processes, eliminating the CPU-GPU memory bottleneck.

  \+--------------------------------------------------------------+  
  |                          GPU VRAM                            |  
  |                                                              |  
  |  \+------------------+  DMA-BUF  \+-------------------------+  |  
  |  | KMS Framebuffer  | \--------\> |   VA-API/NVENC Surface  |  |  
  |  |  (Raw Desktop)   |           | (Color Space/Scale/Enc) |  |  
  |  \+------------------+           \+-------------------------+  |  
  \+----------------------------------------------|---------------+  
                                                 |  
                                                 v  
                                        H.265 Bitstream Out  
                                            (Network)

### **High-Efficiency low-latency Pipeline Blueprints**

#### **FFmpeg Zero-Copy Low-Latency H.265 Capture (AMD & Intel VA-API)**

The following command captures the display directly from the KMS plane and pipes it to the VA-API hardware encoder with zero CPU copy overhead:

Bash  
ffmpeg \-y \-device /dev/dri/renderD128 \-f kmsgrab \-framerate 60 \-i \- \\  
  \-vf 'hwmap=derive\_device=vaapi,scale\_vaapi=w=1920:h=1080:format=nv12' \\  
  \-c:v hevc\_vaapi \-bf 0 \-tune zerolatency \-rc\_mode CBR \-b:v 4000k \\  
  \-g 60 \-idr\_interval 60 \-f mpegts udp://127.0.0.1:9000

**Key Parameter Breakdown:**

* \-device /dev/dri/renderD128: Explicitly points the execution path to the rendering node of the physical GPU.  
* \-f kmsgrab \-i \-: Captures the desktop display directly from the kernel’s active display planes.  
* hwmap=derive\_device=vaapi: Generates an in-GPU mapping to link the raw DRM framebuffer to a VA-API hardware surface without a host-memory round-trip.  
* scale\_vaapi=format=nv12: Performs hardware-accelerated color-space conversion to NV12 (a requirement for most hardware encoders).  
* \-bf 0: Completely disables B-frames (bi-directional prediction), eliminating the frame-reordering latency (which typically costs 1 to 2 frames of delay).  
* \-tune zerolatency: Instructs the hardware encoder to output packets immediately as macroblocks are processed, bypassing internal temporal frame queues.  
* \-rc\_mode CBR \-b:v 4000k: Enforces Constant Bitrate (CBR) rate control to ensure steady, predictable packet spacing over the network.  
* \-g 60 \-idr\_interval 60: Inserts an Instantaneous Decoder Refresh (IDR) frame exactly every 60 frames, ensuring the client browser can decode immediately upon connection without waiting for a distant keyframe.

#### **GStreamer Zero-Copy Low-Latency H.265 Capture**

The equivalent low-latency GStreamer implementation utilizing kmssrc and DMA-BUF sharing:

Bash  
gst-launch-1.0 kmssrc io-mode=dmabuf\! \\  
  video/x-raw(memory:DMABuf),width=1920,height=1080,framerate=60/1\! \\  
  vah265enc low-latency=true bitrate=4000\! \\  
  h265parse\! \\  
  mpegtsmux alignment=7\! \\  
  udpsink host=127.0.0.1 port=9000 sync=false async=false

## **3\. noVNC & WebSocket Integration**

The standard RFB protocol used by VNC is fundamentally designed to transmit raw pixel rectangles. It does not natively support decoding H.265 video streams. To stream low-latency H.265 to an HTML5 VNC client, you must implement a modern protocol wrapper or leverage browser-native WebCodecs.

### **Transport and Containerization Options**

#### **1\. WebRTC (Recommended)**

This represents the most robust solution for interactive streaming, consistently achieving latencies under 50 ms. WebRTC uses UDP/SRTP transport and natively handles packet loss and jitter.

* *Implementation:* Deploy **Selkies-GStreamer**, an open-source remote-desktop streaming platform designed by Google engineers and academic researchers. It uses GStreamer's webrtcbin to capture the display, encode it via NVENC or VA-API, and stream it directly to an HTML5 canvas over WebRTC.

#### **2\. Fragmented MP4 (fMP4) over WebSockets**

If TCP-based streaming is required to bypass strict firewalls, you can packetize the raw HEVC bitstream into a lightweight Fragmented MP4 (fMP4) container.

* *Implementation:* Pipe the FFmpeg output to a Node.js helper. The helper wraps raw H.265 NAL units into sequential, length-prefixed fMP4 boxes and pushes them over a WebSocket connection to the client.

  \+----------------------+      Raw HEVC     \+-------------------+  
  | HW Encoder (FFmpeg)  | \----------------\> |  WebSocket Proxy  |  
  \+----------------------+                   | (fMP4 Packaging)  |  
                                             \+---------|---------|  
                                                       |  
                                                       | WebSocket (WSS)  
                                                       v  
                                             \+-------------------+  
                                             |  HTML5 Browser    |  
                                             | (noVNC Workspace) |  
                                             |         |         |  
                                             |         v         |  
                                             |    WebCodecs      |  
                                             | (VideoDecoder)    |  
                                             |         |         |  
                                             |         v         |  
                                             |   HTML5 Canvas    |  
                                             \+-------------------+

### **noVNC WebCodecs Integration Integration**

Traditional noVNC handles rendering by drawing raw RFB pixel arrays to a 2D canvas context. To support H.265, the noVNC client-side rendering pipeline must be patched to intercept the incoming WebSocket stream and hand it off to the **WebCodecs API** (VideoDecoder).  
The WebCodecs API provides low-level, hardware-accelerated decoding directly inside the browser sandbox.

#### **Client-Side WebCodecs Rendering Script**

The following JavaScript snippet runs on the client browser. It establishes a binary WebSocket connection, decodes incoming H.265 frames at hardware speeds, and draws them to the noVNC workspace canvas:

JavaScript  
const canvas \= document.getElementById("novnc-canvas");  
const ctx \= canvas.getContext("2d");

const decoder \= new VideoDecoder({  
  output: (frame) \=\> {  
    // Perform a zero-copy draw directly from GPU surface to the browser canvas  
    ctx.drawImage(frame, 0, 0, canvas.width, canvas.height);  
    frame.close(); // Crucial: You must close the frame to prevent GPU memory leaks\!  
  },  
  error: (e) \=\> {  
    console.error("WebCodecs Hardware Decoder Error: ", e);  
  }  
});

// Configure the H.265 profile  
// "hvc1.1.6.L93.B0" translates to HEVC Main Profile, Main Tier, Level 3.1  
decoder.configure({  
  codec: "hvc1.1.6.L93.B0",  
  codedWidth: 1920,  
  codedHeight: 1080,  
  hardwareAcceleration: "prefer-hardware"  
});

// Establish connection to Websockify proxy  
const ws \= new WebSocket("ws://arch-host:6080/hevc-stream");  
ws.binaryType \= "arraybuffer";

ws.onmessage \= async (event) \=\> {  
  const binaryData \= new Uint8Array(event.data);  
    
  // Extract NAL unit metadata  
  const isKeyframe \= (binaryData\[1\] & 0x7E) \>\> 1 \=== 19; // NAL Unit Type 19 (IDR)  
    
  const chunk \= new EncodedVideoChunk({  
    type: isKeyframe? "key" : "delta",  
    timestamp: performance.now() \* 1000, // Microseconds  
    data: binaryData  
  });  
    
  decoder.decode(chunk);  
};

## **4\. Latency Optimization & Troubleshooting**

Achieving consistent sub-30 ms end-to-end latency requires deep optimization of the Arch Linux kernel, scheduler, and hardware power states.

### **Host-Level Low-Latency Tuning**

#### **1\. Deploy a Real-Time Kernel**

The default Arch Linux kernel optimizes for throughput, not deterministic execution latency. Install the preemptive real-time kernel to guarantee that encoding processes are never blocked by background system threads:

Bash  
sudo pacman \-S linux-rt-lts linux-rt-lts-headers

#### **2\. Kernel Boot Parameters**

Edit /etc/default/grub and append the following parameters to GRUB\_CMDLINE\_LINUX\_DEFAULT to disable power-saving CPU transitions and thread rescheduling jitter:

Ini, TOML  
threadirqs mitigations=off pci=assign-busses nohz=on hpet=disable usbcore.autosuspend=-1 split\_lock\_detect=off intel\_idle.max\_cstate=1

Apply the changes and reboot:

Bash  
sudo grub-mkconfig \-o /boot/grub/grub.cfg

#### **3\. CPU and GPU Performance Locking**

Dynamic frequency scaling adds a critical delay as the hardware ramps up clock speeds in response to sudden video motion. You must lock the hardware in maximum performance states.

* **CPU Governor Configuration:**  
  Install cpupower and disable user-space daemon interference:  
  Bash  
  sudo pacman \-S cpupower  
  sudo systemctl mask power-profiles-daemon

  Set the default governor to performance in /etc/default/cpupower:  
  Ini, TOML  
  governor='performance'

  Enable and start the service:  
  Bash  
  sudo systemctl enable \--now cpupower.service

* **NVIDIA GPU Clock Locking:**  
  Enable Persistence Mode and lock the graphics clocks to prevent GPU downclocking:  
  Bash  
  sudo nvidia-smi \-pm 1  
  sudo nvidia-smi \-lgc 1500,1500

* **AMD GPU Clock Locking:**  
  Force AMD Power Play tables to remain at peak performance states:  
  Bash  
  echo performance | sudo tee /sys/class/drm/card0/device/power\_dpm\_state

#### **4\. Thread Affining & Interrupt Optimization**

To prevent hardware encoding tasks from sharing cores with network interrupts or disk operations, bind your streaming components to specific cores:

* Disable timer migration across CPU cores:  
  Bash  
  echo 0 | sudo tee /proc/sys/kernel/timer\_migration

* Disable real-time CPU scheduling runtime limits to prevent the kernel from throttling your low-latency encoder:  
  Bash  
  echo \-1 | sudo tee /proc/sys/kernel/sched\_rt\_runtime\_us

### **Measuring and Profiling Sub-Millisecond Bottlenecks**

To debug and eliminate latency spikes, you must profile every phase of the pipeline.

\+-----------------------------------------------------------------------+  
|                    END-TO-END LATENCY PIPELINE                        |  
|                                                                       |  
|  \+---------+   \+---------+   \+------------+   \+---------+   \+-------+ |  
|  | Capture |--\>| Encode  |--\>| Transport  |--\>| Decode  |--\>| Render| |  
|  | (Kernel)|   |  (GPU)  |   | (WebSocket)|   | (Browser|   | (HTML)| |  
|  \+---------+   \+---------+   \+------------+   \+---------+   \+-------+ |  
|       |             |              |               |            |     |  
|       \+------+------+              |               \+-----+------+     |  
|              |                     v                     |            |  
|              v             Network RTT (Ping)            v            |  
|       Encoding Latency                             Decoding Latency   |  
\+-----------------------------------------------------------------------+

#### **Calculating True Glass-to-Glass Latency**

The absolute end-to-end latency of a video pipeline is calculated mathematically as:

$$\\Delta t\_{\\text{g2g}} \= T\_{\\text{client}} \- T\_{\\text{host}}$$  
Where $T\_{\\text{client}}$ represents the time a frame is displayed in the browser viewport, and $T\_{\\text{host}}$ represents the actual system time on the host when the frame was captured.  
To measure this value with sub-millisecond precision:

1. **Generate a High-Precision Clock:**  
   Run a terminal-based epoch clock loop on the Arch host:  
   Bash  
   while true; do echo $(($(date \+%s%N)/10000000)); sleep 0.001; done

2. **Display Side-by-Side:**  
   Arrange the native host terminal displaying the clock loop and the browser-based noVNC workspace canvas side-by-side.  
3. **Capture a Photographic Benchmark:**  
   Use a high-speed camera (e.g., a smartphone camera recording at 240 FPS) to take a single photograph containing both screens.  
4. **Perform Temporal Subtraction:**  
   Read the millisecond timestamps shown in both the host terminal and the remote browser. Subtract the two values to calculate the exact glass-to-glass latency.

#### **Profiling Component-Level Jitter**

* **Pipeline Jitter Tracking:** Install rt-tests from the official repositories. Use cyclictest to verify host scheduler predictability under load, ensuring background processes are not causing CPU scheduling starvation on your encoding threads.  
* **WebCodecs Jitter Profiling:** Inspect browser-side decoding performance by opening Google Chrome and navigating to chrome://media-internals. Under the WebCodecs or HTML5 Video player instances, analyze the exact decoding queue size (decodeQueueSize) and individual frame drop logs. High values or dropped frames indicate backpressure, requiring a reduction in target bitrate or frame rate.