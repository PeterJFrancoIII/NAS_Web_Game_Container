# **Ultra-Lightweight Multi-Instance Command & Conquer: Red Alert 2 Deployment on Synology DS225+ via Containerized Arch Linux and Web-VNC**

## **Host Hardware Evaluation and Memory Optimization**

Deploying concurrent, interactive graphical software instances on a network-attached storage platform requires a rigorous assessment of the host’s physical hardware boundaries.1 The Synology DS225+ operates under strict constraints, depending on its specific manufacturing revision.1 Early revisions are built around the Intel Celeron J4125, a quad-core, 14nm Gemini Lake Refresh processor operating at a 2.0 GHz base frequency and up to 2.7 GHz burst.1 Later revisions feature the AMD Ryzen R1600, a dual-core, four-thread processor running at 2.0 GHz base.3 Crucially, the system is shipped with a baseline of only 2 GB of non-ECC system memory.1 While the Intel configuration supports a maximum of 6 GB of RAM via a single DDR4 SODIMM expansion slot 1, the AMD revision integrates DDR5 and supports un-buffered expansion.3

| Hardware Spec Category | Intel Celeron J4125 Revision | AMD Ryzen R1600 Revision | Virtualization Footprint Constraints |
| :---- | :---- | :---- | :---- |
| **CPU Architecture** | x86\_64, 4 Cores / 4 Threads, 2.7 GHz Burst 1 | x86\_64, 2 Cores / 4 Threads, 2.0 GHz Base 3 | Native execution of x86 instructions; no emulation overhead. |
| **Baseline Memory** | 2 GB DDR4 Non-ECC (Onboard) 1 | 2 GB DDR5 Non-ECC (Onboard) 3 | Major bottleneck; traditional VMs exhaust RAM.2 |
| **Expansion Limit** | 6 GB (2 GB \+ 4 GB SODIMM) 1 | User-expandable (Unofficially up to 16 GB+) 3 | Requires strict minimization of guest OS memory layers. |
| **Network Interface** | 1x 2.5 Gbps RJ-45, 1x 1 Gbps RJ-45 1 | 2x 1 Gbps RJ-45 LAN Ports 3 | Direct Layer 2 routing preferred to reduce CPU interrupts.5 |

Running multi-instance graphical deployments under these memory constraints rules out standard hypervisor-based virtualization.2 Synology Virtual Machine Manager (VMM) incurs a significant virtualization penalty, requiring a minimum static allocation of 1 GB of RAM per guest operating system instance.2 This footprint stems from the need to run separate kernel spaces, virtualized hardware drivers, and system daemons.2 Running two such virtual machines on a baseline 2 GB host completely exhausts the available system RAM, triggering the host kernel’s Out-Of-Memory (OOM) killer and rendering the primary DiskStation Manager (DSM) operating system unstable.2  
Containerization via Docker represents the only viable architecture for this deployment.2 Docker containers bypass hardware emulation by sharing the host Linux kernel directly.6 By utilizing a tailored Arch Linux base image, memory usage is restricted solely to the active game binaries and the lightweight display translation layers.7 Arch Linux is highly suited for this deployment due to its rolling-release model and granular package control, allowing the creation of a minimal runtime environment without unnecessary background processes.9

## **Headless Display Pipeline and Resource Minimization**

To stream the graphical output of *Command & Conquer: Red Alert 2* to separate client web browsers, the container stack must utilize an ultra-lightweight, headless rendering and translation pipeline.11

  \+-------------------------------------------------------------+  
  |                   Arch Linux Container                      |  
  |                                                             |  
  |  \+------------+     \+----------+     \+-------------------+  |  
  |  |   Wine     | \--\> |   Xvfb   | \--\> |      x11vnc       |  |  
  |  |  (Game)    |     | (Virtual |     |   (VNC Server)    |  |  
  |  \+------------+     | Screen)  |     \+-------------------+  |  
  |                     \+----------+               |            |  
  |                                                v            |  
  |  \+------------+                      \+-------------------+  |  
  |  | Web Browser| \<=================== |    websockify     |  |  
  |  |  (Client)  |      (noVNC)         | (WebSocket Proxy) |  |  
  |  \+------------+                      \+-------------------+  |  
  \+-------------------------------------------------------------+

### **X Virtual Framebuffer (Xvfb)**

Xvfb functions as an X11 display server that performs all graphical rendering operations directly in virtual system memory without requiring a physical GPU.12 The memory overhead of a raw virtual frame buffer is calculated as:  
![][image1]  
For *Red Alert 2* running at a standard optimized resolution of ![][image2] at 16-bit color depth with double buffering, the frame buffer consumes minimal memory 14:  
![][image3]  
This low memory footprint makes Xvfb highly efficient compared to a full desktop environment.7

### **Openbox Window Manager**

Rather than running full desktop environments such as XFCE or LXDE, the container uses Openbox, a minimalist, highly configurable stacking window manager.7 Openbox manages window placement, focus, and launching scripts with a memory footprint of only 8 MB to 12 MB of RAM.7

### **VNC Server (x11vnc)**

The VNC server captures the in-memory frame buffer generated by Xvfb.12 Because x11vnc does not require a physical display driver and reads directly from the virtual shared memory segments of Xvfb, it operates with minimal CPU cycles.12

### **Websockify & noVNC**

The RFB (Remote Framebuffer) protocol used by VNC is not natively supported by modern HTML5 web browsers.17 Websockify acts as a WebSocket-to-TCP proxy, capturing WebSocket traffic from incoming web browser clients and translating it into raw RFB packets for the VNC server.18 noVNC, a pure JavaScript library rendered on the client browser, then displays the stream via an HTML5 canvas element.11

### **Arch Linux WOW64 Optimization**

Historically, running 32-bit Windows applications on 64-bit Linux distributions via Wine required enabling the multilib repository, which downloaded duplicate 32-bit graphics, system, and audio libraries.10 This added up to 1.5 GB of disk space and increased memory usage during library linking.10  
The containerized Arch Linux environment avoids this by using Wine's WoW64 (Windows 32-bit on Windows 64-bit) mode.8 Under WoW64, 32-bit Windows system calls are intercepted and translated directly into 64-bit Wine instructions via thunking layers.20 This allows the container to run without any 32-bit Linux host libraries, reducing the base container image size and operational RAM requirements.8

## **Game Engine Compatibility and Audio Emulation Workarounds**

Running a legacy Windows 95/98 game inside a modern headless Linux container requires resolving several key compatibility and rendering issues.6

### **Bypassing the Audio Initialization Crash**

The *Red Alert 2* and *Yuri's Revenge* engines contain a hardcoded routine that queries the operating system for a functional, active audio playback device during startup.6 In a headless Docker container, no physical audio hardware is mapped.6 If the game receives an empty hardware description array from the OS, it immediately crashes with an unhandled exception.6  
To prevent this crash without running a full PulseAudio or PipeWire server on the Synology host (which would consume excessive CPU and RAM), the container’s Wine environment is configured with a dummy audio driver.21 By executing winetricks settings sound=alsa or writing directly to the Wine registry, Wine is forced to register a mock ALSA loopback device.23 This satisfies the game engine's query with zero CPU and memory overhead.23

Bash  
\# Force the Wine prefix driver to link to a dummy ALSA reference  
wine reg add "HKEY\_CURRENT\_USER\\Software\\Wine\\Drivers" /v "Audio" /t REG\_SZ /d "alsa" /f

### **DirectDraw Acceleration via cnc-ddraw**

*Red Alert 2* relies on Microsoft's legacy DirectDraw API, which modern operating systems do not support efficiently.27 This often causes low frame rates, invisible mouse cursors, and display freezing.27  
To resolve this, the open-source cnc-ddraw wrapper is placed in the game directory.27 cnc-ddraw intercepts legacy DirectDraw calls and translates them into modern OpenGL or GDI instructions.29 In a headless VNC environment, utilizing the GDI or OpenGL renderer combined with Mesa's CPU-based software rasterizer (swrast) ensures high compatibility and prevents rendering glitches.29

### **IPX Protocol to UDP Translation**

The original multiplayer engine of *Red Alert 2* communicates using the legacy IPX (Internetwork Packet Exchange) protocol.34 Modern IP stacks utilize TCP/IP, and Linux kernels do not natively route IPX frames without complex driver compilation.35  
To enable LAN multiplayer, a modified wsock32.dll wrapper is placed in the game folder of both instances.35 This library intercepts legacy IPX socket initialization calls and dynamically translates them into UDP multicast packets on port 7460, enabling multiplayer gameplay over standard TCP/IP networks.36

  \+-----------------------+               \+-----------------------+  
  |      Game Engine      |               |      Game Engine      |  
  |      Instance 1       |               |      Instance 2       |  
  |                       |               |                       |  
  |  \+-----------------+  |               |  \+-----------------+  |  
  |  | Legacy IPX Calls|  |               |  | Legacy IPX Calls|  |  
  |  \+-----------------+  |               |  \+-----------------+  |  
  |           |           |               |           |           |  
  \+-----------|-----------+               \+-----------|-----------+  
              v                                       v  
     \+-----------------+                     \+-----------------+  
     |   wsock32.dll   |                     |   wsock32.dll   |  
     | (IPX to UDP IP) |                     | (IPX to UDP IP) |  
     \+-----------------+                     \+-----------------+  
              |                                       |  
              \+-----------\> Local Network (UDP) \<-----+

### **Registry Serial Validation Collision**

As a copy-protection measure, the Westwood engine prevents multiplayer matches if it detects duplicate serial numbers on the same local network.39 Since the containers use identical base game files, they will naturally use the same serial number stored in the Wine registry.39  
This check is bypassed by injecting unique serial values into the virtual registry database of each container’s Wine prefix during initialization.20

Bash  
\# Instance 1 Serial Injection  
wine reg add "HKEY\_LOCAL\_MACHINE\\Software\\WOW6432Node\\Westwood\\Red Alert 2" /v "Serial" /t REG\_SZ /d "11112222333344445555" /f

\# Instance 2 Serial Injection  
wine reg add "HKEY\_LOCAL\_MACHINE\\Software\\WOW6432Node\\Westwood\\Red Alert 2" /v "Serial" /t REG\_SZ /d "55554444333322221111" /f

## **Network Topology: Custom Bridge vs. Macvlan on Synology DSM**

To allow the multiplayer lobby to discover both game instances, each container must be assigned an internally static IP address.5 Synology DSM offers two primary network configurations to achieve this.5

### **1\. Dedicated Macvlan Network (L2 Bridge)**

The macvlan driver assigns a unique, physically routable MAC address to each container's virtual network interface.5 The containers appear as distinct physical devices connected directly to the local network, allowing them to lease or be assigned static IP addresses on the primary LAN subnet (e.g., 192.168.1.201 and 192.168.1.202).5  
Because Synology DSM manages physical network interfaces within an Open vSwitch (OVS) layer to support virtualization and bonding, the macvlan network must target the underlying OVS interface (typically ovs\_eth0 or ovs\_eth1) rather than the raw interface.5

Bash  
\# Execute over SSH to construct the Macvlan driver layer  
sudo docker network create \-d macvlan \\  
  \--subnet=192.168.1.0/24 \\  
  \--gateway=192.168.1.1 \\  
  \--ip-range=192.168.1.200/29 \\  
  \-o parent=ovs\_eth0 \\  
  macvlan\_lan

### **2\. Custom Docker Bridge Network (L3 NAT)**

A custom bridge network creates an isolated virtual subnet within the Docker engine on the Synology host (e.g., 172.22.0.0/16).41 The containers are assigned static IPs within this private subnet.41  
To allow external clients to access the game displays, the noVNC ports are mapped to different ports on the Synology host’s primary IP (e.g., mapping host port 6081 to container 1 port 6080, and host port 6082 to container 2 port 6080).40 Because the containers reside on the same private subnet, the game instances can communicate directly over their internal static IPs.41

| Evaluation Factor | Macvlan Network (L2 Bridge) | Custom Bridge Network (L3 NAT) |
| :---- | :---- | :---- |
| **IP Routing Layer** | Direct exposure to the local network; each container gets its own IP.40 | Isolated private subnet; mapped to host ports.41 |
| **Port Mapping** | No port mapping required; both use default port 6080\.40 | Maps ports to the host IP (e.g., ports 6081 and 6082).40 |
| **DSM Update Stability** | Low; DSM updates can reset OVS interfaces.5 | High; completely self-contained within Docker Compose.41 |
| **Host Communication** | No direct host-to-container communication by default.43 | Native communication with the host and other containers.41 |
| **System Resource Impact** | Extremely low; offloads packet processing to switches.5 | Low; requires minimal host kernel NAT processing.41 |
| **Multicast Support** | Native; UDP multicast passes directly through LAN.40 | Supported natively within the internal private bridge subnet.41 |

### **Design Recommendation for Synology DS225+**

To ensure maximum stability and ease of deployment, **the Custom Docker Bridge Network is the recommended topology**.  
Using a custom bridge network keeps the deployment self-contained within a standard docker-compose.yml file, avoiding the need for manual SSH commands on the Synology host.41 It also ensures the configuration survives DSM system updates and avoids potential IP address collisions on the local router.40  
Since multiplayer communication occurs solely between the two container instances on the same host, the private bridge network provides an efficient, isolated transport layer for UDP multicast traffic.41 The client machines can access each game's display by navigating to the Synology host’s IP at ports 6081 and 6082 respectively.40

## **Step-by-Step Deployment and Configuration Blueprints**

This section provides the complete deployment files for the optimized multi-instance stack on the Synology DS225+.1

### **1\. Ultra-Lightweight Dockerfile**

This Dockerfile constructs a minimalist Arch Linux base image.8 It configures pacman's NoExtract directive to exclude man pages, locales, and documentation, reducing the base image size.9 It then installs Wine WoW64 and cloning the noVNC and websockify repositories directly, avoiding the need for heavy build tools.8

Dockerfile  
FROM archlinux:latest

\# Optimize pacman and install lightweight display utilities and Wine WoW64  
RUN echo "NoExtract \= usr/share/doc/\* usr/share/help/\* usr/share/locale/\* usr/share/man/\* usr/share/licenses/\*" \>\> /etc/pacman.conf && \\  
    pacman \-Syu \--noconfirm && \\  
    pacman \-S \--noconfirm \\  
    wine \\  
    wine-gecko \\  
    xorg-server-xvfb \\  
    openbox \\  
    x11vnc \\  
    supervisor \\  
    alsa-lib \\  
    alsa-utils \\  
    git \\  
    python \\  
    python-numpy && \\  
    pacman \-Scc \--noconfirm

\# Fetch static client files for noVNC and websockify  
RUN git clone \--depth 1 https://github.com/novnc/noVNC.git /opt/novnc && \\  
    git clone \--depth 1 https://github.com/novnc/websockify.git /opt/novnc/utils/websockify && \\  
    ln \-s /opt/novnc/vnc.html /opt/novnc/index.html

\# Configure system execution context  
RUN useradd \-m \-s /bin/bash commander && \\  
    mkdir \-p /opt/config /home/commander/.wine && \\  
    chown \-R commander:commander /opt /home/commander

USER commander  
WORKDIR /home/commander

\# Set system variables  
ENV DISPLAY=:1  
ENV WINEARCH=win64  
ENV WINEPREFIX=/home/commander/.wine  
ENV WINEDEBUG=-all

COPY \--chown=commander:commander supervisord.conf /opt/config/supervisord.conf  
COPY \--chown=commander:commander entrypoint.sh /opt/config/entrypoint.sh

RUN chmod \+x /opt/config/entrypoint.sh

ENTRYPOINT \["/opt/config/entrypoint.sh"\]

### **2\. Comprehensive docker-compose.yml**

This manifest defines both game instances as separate services pinned to static IPs on a custom bridge network.41 It maps the client web interfaces to host ports 6081 and 6082 respectively, while using shared volume mounts to manage game assets.6

YAML  
version: '3.8'

services:  
  ra2-player-1:  
    build:.  
    container\_name: ra2-player-1  
    restart: unless-stopped  
    security\_opt:  
      \- no-new-privileges:true  
    volumes:  
      \- /volume1/docker/ra2-shared-assets:/home/commander/game\_files:ro  
      \- /volume1/docker/ra2-instance-1/wineprefix:/home/commander/.wine:rw  
    environment:  
      \- PLAYER\_ID=1  
      \- PLAYER\_SERIAL=11112222333344445555  
      \- RESOLUTION=1024x768  
      \- VNC\_PASSWD=player1password  
    ports:  
      \- "6081:6080"  
    networks:  
      ra2\_net:  
        ipv4\_address: 172.22.0.10

  ra2-player-2:  
    build:.  
    container\_name: ra2-player-2  
    restart: unless-stopped  
    security\_opt:  
      \- no-new-privileges:true  
    volumes:  
      \- /volume1/docker/ra2-shared-assets:/home/commander/game\_files:ro  
      \- /volume1/docker/ra2-instance-2/wineprefix:/home/commander/.wine:rw  
    environment:  
      \- PLAYER\_ID=2  
      \- PLAYER\_SERIAL=55554444333322221111  
      \- RESOLUTION=1024x768  
      \- VNC\_PASSWD=player2password  
    ports:  
      \- "6082:6080"  
    networks:  
      ra2\_net:  
        ipv4\_address: 172.22.0.20

networks:  
  ra2\_net:  
    driver: bridge  
    ipam:  
      driver: default  
      config:  
        \- subnet: 172.22.0.0/16  
          gateway: 172.22.0.1

### **3\. Execution Control Script: entrypoint.sh**

This script manages initialization tasks before starting supervisord.12 It copies game assets to the active Wine prefix, configures the mock ALSA audio driver, and injects unique serial numbers and registry settings for each container.6

Bash  
\#\!/bin/bash  
set \-e

\# Initialize the virtual Wine prefix  
if; then  
    echo "Initializing virtual Wine prefix..."  
    wineboot \-u  
    mkdir \-p "$WINEPREFIX/drive\_c/RA2"  
      
    \# Copy shared game files to the active prefix  
    cp \-r /home/commander/game\_files/\* "$WINEPREFIX/drive\_c/RA2/"  
fi

\# Configure the dummy ALSA audio driver to prevent startup crashes  
wine reg add "HKEY\_CURRENT\_USER\\Software\\Wine\\Drivers" /v "Audio" /t REG\_SZ /d "alsa" /f

\# Inject unique serial keys to allow LAN gameplay  
wine reg add "HKEY\_LOCAL\_MACHINE\\Software\\WOW6432Node\\Westwood\\Red Alert 2" /v "Serial" /t REG\_SZ /d "$PLAYER\_SERIAL" /f

\# Set execution permissions  
chmod \-R 755 "$WINEPREFIX/drive\_c/RA2"

\# Start the process supervisor  
exec supervisord \-c /opt/config/supervisord.conf

### **4\. Process Supervisor: supervisord.conf**

This configuration utilizes supervisord to manage the process lifecycle within the container, ensuring that any failed service is automatically restarted with minimal system overhead.12

Ini, TOML  
\[supervisord\]  
nodaemon=true  
logfile=/dev/null  
logfile\_maxbytes=0

\[program:xvfb\]  
command=Xvfb :1 \-screen 0 %(ENV\_RESOLUTION)sx16  
priority=10  
autorestart=true  
stdout\_logfile=/dev/null  
stderr\_logfile=/dev/null

\[program:openbox\]  
command=openbox-session  
priority=20  
autorestart=true  
environment=DISPLAY=":1"  
stdout\_logfile=/dev/null  
stderr\_logfile=/dev/null

\[program:x11vnc\]  
command=x11vnc \-display :1 \-localhost \-passwd %(ENV\_VNC\_PASSWD)s \-forever \-shared \-bg  
priority=30  
autorestart=true  
stdout\_logfile=/dev/null  
stderr\_logfile=/dev/null

\[program:websockify\]  
command=python /opt/novnc/utils/websockify/run 6080 localhost:5900 \--web /opt/novnc  
priority=40  
autorestart=true  
stdout\_logfile=/dev/null  
stderr\_logfile=/dev/null

\[program:game\]  
command=wine "$WINEPREFIX/drive\_c/RA2/RA2MD.exe" \-SPEEDCONTROL  
priority=50  
autorestart=false  
environment=DISPLAY=":1",WINEDLLOVERRIDES="ddraw=n,b;wsock32=n,b"  
directory=%%WINEPREFIX%%/drive\_c/RA2  
stdout\_logfile=/dev/null  
stderr\_logfile=/dev/null

### **5\. Highly Optimized ddraw.ini**

This file is placed in the game directory (/volume1/docker/ra2-shared-assets) to configure cnc-ddraw.27 It limits rendering frame rates and maps legacy DirectDraw calls directly to OpenGL software rasterization.29

Ini, TOML  
\[ddraw\]  
width=1024  
height=768  
fullscreen=true  
windowed=false  
maintas=true  
boxing=false  
maxfps=60  
vsync=false  
adjmouse=true  
renderer=opengl  
border=false  
noactivateapp=true  
maxgameticks=0  
minfps=-1

### **6\. Video Configuration for RA2.ini and RA2MD.ini**

To ensure perfect rendering synchronization with the display translation layers, the video configuration blocks inside the primary game configuration files (RA2.ini and RA2MD.ini) must match the display pipeline's resolution 27:

Ini, TOML  
\[Video\]  
AllowHiResModes=yes  
VideoBackBuffer=no  
ScreenWidth=1024  
ScreenHeight=768  
StretchMovies=yes

## **Analytical Conclusion and Actionable Operational Checklist**

This containerized architecture provides an efficient way to host legacy Windows applications on restricted network-attached storage platforms.2 By using a shared-kernel architecture on an optimized Arch Linux base image, this solution achieves significant resource savings compared to traditional hardware virtualization.2

\+------------------------------------------------------------+  
|                  SYNOLOGY DSM 7.2 HOST                     |  
|                                                            |  
|  \+------------------------------------------------------+  |  
|  |                Docker Engine Daemon                  |  |  
|  |                                                      |  |  
|  |  \+------------------------+  \+--------------------+  |  |  
|  |  |  ra2-player-1 Container|  |ra2-player-2 Cont.  |  |  |  
|  |  |  Static IP: 172.22.0.10|  |Static IP: 172.22.0.|  |  |  
|  |  \+------------+-----------+  \+---------+----------+  |  |  
|  |               |                        |             |  |  
|  |               \+-----------+------------+             |  |  
|  |                           |                          |  |  
|  |                           v                          |  |  
|  |                Docker Bridge (\`ra2\_net\`)             |  |  
|  \+---------------------------|--------------------------+  |  
|                              |                             |  
\+------------------------------|-----------------------------+  
                               |  
                        Physical Switch  
                               |  
             \+-----------------+-----------------+  
             | (VNC over HTTP)                   | (VNC over HTTP)  
             v                                   v  
   Client 1 Browser                    Client 2 Browser  
   (Host\_IP:6081)                      (Host\_IP:6082)

To ensure a successful deployment on the Synology DS225+, system administrators should follow this operational checklist 1:

* **Step 1: Expand System RAM (Highly Recommended)** Install an additional 4 GB DDR4 or DDR5 non-ECC SODIMM into the single expansion slot of the DS225+.1 Expanding total memory to 6 GB prevents potential out-of-memory (OOM) issues and ensures smooth operation alongside other DSM services.2  
* **Step 2: Set Up Shared Storage Volumes** On the Synology host, create the directory structure /volume1/docker/ra2-shared-assets and upload the raw *Red Alert 2* and *Yuri's Revenge* installation files.6 Ensure the optimized ddraw.ini, wsock32.dll, and initialized RA2MD.ini configuration files are present in the directory.29  
* **Step 3: Define Firewall Rules in DSM** Because DSM treats Docker's virtual network bridges as external networks, the Synology firewall may block outgoing UDP multicast traffic.41 Navigate to **Control Panel \> Security \> Firewall** and create an allow rule for the container subnet range 172.22.0.0/16.41 This rule should be placed near the top of the evaluation list.41  
* **Step 4: Initialize and Launch the Container Stack** Connect to the Synology host over SSH using administrative privileges, navigate to the directory containing the docker-compose.yml file, and execute the initialization command 5:  
  Bash  
  sudo docker-compose up \-d \--build

* **Step 5: Connect Clients** Open an HTML5-compliant web browser on each client machine.12 Navigate to the Synology host's IP address at port 6081 for Player 1, and port 6082 for Player 2\.40 Once connected to the noVNC workspace, players can launch the multiplayer mode within *Yuri's Revenge*, where the two container instances will discover each other over the private network bridge.41

#### **Works cited**

1. Product Specifications \- DS225+ \- Synology, accessed June 8, 2026, [https://global.download.synology.com/download/Document/Hardware/ProductSpec/DiskStation/25-year/DS225+/enu/Product\_Spec\_DS225+\_enu.pdf](https://global.download.synology.com/download/Document/Hardware/ProductSpec/DiskStation/25-year/DS225+/enu/Product_Spec_DS225+_enu.pdf)  
2. Synology DS225+ Review (vs. DS224+): A Solid 2.5GbE Upgrade | Dong Knows Tech, accessed June 8, 2026, [https://dongknows.com/synology-ds225-plus-review/](https://dongknows.com/synology-ds225-plus-review/)  
3. Synology DS225+ Review: Best 2-Bay Under $500 in 2026? | Need to Know IT, accessed June 8, 2026, [https://needtoknowit.com.au/blog/synology-ds225-plus-review-australia/](https://needtoknowit.com.au/blog/synology-ds225-plus-review-australia/)  
4. Synology Disk Station DS225+ \- NAS server \- CDW, accessed June 8, 2026, [https://www.cdw.com/product/synology-disk-station-ds225-nas-server/8461432](https://www.cdw.com/product/synology-disk-station-ds225-nas-server/8461432)  
5. Assigning IP Addresses to Synology Containers | Justin Wyne, accessed June 8, 2026, [https://justinwyne.com/posts/assigning-ip-addresses-to-synology-containers/](https://justinwyne.com/posts/assigning-ip-addresses-to-synology-containers/)  
6. GitHub \- kazenshi/cncra2yr: Running Command and Conquer: Red ..., accessed June 8, 2026, [https://github.com/loligans/cncra2yr](https://github.com/loligans/cncra2yr)  
7. Openbox \- ArchWiki, accessed June 8, 2026, [https://wiki.archlinux.org/title/Openbox](https://wiki.archlinux.org/title/Openbox)  
8. How to Install Wine on Arch Linux, accessed June 8, 2026, [https://wine.htmlvalidator.com/install-wine-on-arch-linux.html](https://wine.htmlvalidator.com/install-wine-on-arch-linux.html)  
9. building docker image with Arch Linux / Community Contributions / Arch Linux Forums, accessed June 8, 2026, [https://bbs.archlinux.org/viewtopic.php?id=205601](https://bbs.archlinux.org/viewtopic.php?id=205601)  
10. Wine (Archlinux) (DONE) it was the MULTILIB :: Steam for Linux General Discussions, accessed June 8, 2026, [https://steamcommunity.com/app/221410/discussions/0/687495779967993459/](https://steamcommunity.com/app/221410/discussions/0/687495779967993459/)  
11. docker-novnc-baseimage \- Duke's Gitlab, accessed June 8, 2026, [https://gitlab.oit.duke.edu/docker-novnc-baseimage/docker-novnc-baseimage](https://gitlab.oit.duke.edu/docker-novnc-baseimage/docker-novnc-baseimage)  
12. Running Firefox in Docker? Yes, with a GUI and noVNC | by Daniel Pepuho \- Medium, accessed June 8, 2026, [https://danielpepuho.medium.com/running-firefox-in-docker-yes-with-a-gui-and-novnc-8f5f9ca9dbdb](https://danielpepuho.medium.com/running-firefox-in-docker-yes-with-a-gui-and-novnc-8f5f9ca9dbdb)  
13. Dockerfile setup for an Arch Linux based remote desktop \- Stack Overflow, accessed June 8, 2026, [https://stackoverflow.com/questions/77259064/dockerfile-setup-for-an-arch-linux-based-remote-desktop](https://stackoverflow.com/questions/77259064/dockerfile-setup-for-an-arch-linux-based-remote-desktop)  
14. Guide :: Red Alert 2 on Linux via CNCNET \- Steam Community, accessed June 8, 2026, [https://steamcommunity.com/sharedfiles/filedetails/?id=3175193520](https://steamcommunity.com/sharedfiles/filedetails/?id=3175193520)  
15. Red Alert with Linux (Wine), accessed June 8, 2026, [http://ra.afraid.org/html/extra/linuxra.html](http://ra.afraid.org/html/extra/linuxra.html)  
16. naei/docker-openbox-novnc \- GitHub, accessed June 8, 2026, [https://github.com/naei/docker-openbox-novnc](https://github.com/naei/docker-openbox-novnc)  
17. GitHub \- wavyland/novnc: A multi-arch Docker image for noVNC, accessed June 8, 2026, [https://github.com/wavyland/novnc](https://github.com/wavyland/novnc)  
18. Websockify is a WebSocket to TCP proxy/bridge. This allows a browser to connect to any application/server/service. \- GitHub, accessed June 8, 2026, [https://github.com/novnc/websockify](https://github.com/novnc/websockify)  
19. noVNC: HTML VNC client library and application, accessed June 8, 2026, [https://novnc.com/noVNC/](https://novnc.com/noVNC/)  
20. Wine \- ArchWiki, accessed June 8, 2026, [https://wiki.archlinux.org/title/Wine](https://wiki.archlinux.org/title/Wine)  
21. Tutorial: Running CnC2:YR \+ CnCNet within a docker container : r/redalert2 \- Reddit, accessed June 8, 2026, [https://www.reddit.com/r/redalert2/comments/1abv1iq/tutorial\_running\_cnc2yr\_cncnet\_within\_a\_docker/](https://www.reddit.com/r/redalert2/comments/1abv1iq/tutorial_running_cnc2yr_cncnet_within_a_docker/)  
22. Fix missing or undetected audio output device in Windows \- Microsoft Support, accessed June 8, 2026, [https://support.microsoft.com/en-us/windows/fix-missing-or-undetected-audio-output-device-in-windows-5504aed3-2c01-4214-89d1-9e8dbe6828e8](https://support.microsoft.com/en-us/windows/fix-missing-or-undetected-audio-output-device-in-windows-5504aed3-2c01-4214-89d1-9e8dbe6828e8)  
23. \[Solved\] wine sound not working (pulseaudio) / Newbie Corner / Arch Linux Forums, accessed June 8, 2026, [https://bbs.archlinux.org/viewtopic.php?id=135032](https://bbs.archlinux.org/viewtopic.php?id=135032)  
24. No sound when running wine programs, only while other audio playing in background. : r/linux\_gaming \- Reddit, accessed June 8, 2026, [https://www.reddit.com/r/linux\_gaming/comments/11munz5/no\_sound\_when\_running\_wine\_programs\_only\_while/](https://www.reddit.com/r/linux_gaming/comments/11munz5/no_sound_when_running_wine_programs_only_while/)  
25. \[Request\]: Support changing audio drivers, like 'winetricks sound=alsa' · Issue \#1950 · bottlesdevs/Bottles \- GitHub, accessed June 8, 2026, [https://github.com/bottlesdevs/Bottles/issues/1950](https://github.com/bottlesdevs/Bottles/issues/1950)  
26. How to change the default audio in Wine to Alsa only \- Ask Ubuntu, accessed June 8, 2026, [https://askubuntu.com/questions/77210/how-to-change-the-default-audio-in-wine-to-alsa-only](https://askubuntu.com/questions/77210/how-to-change-the-default-audio-in-wine-to-alsa-only)  
27. Fix Red Alert 2 on Linux and Steam \- Blogs by Baraa, accessed June 8, 2026, [https://mbaraa.com/blog/fix-red-alert-2-on-linux-and-steam](https://mbaraa.com/blog/fix-red-alert-2-on-linux-and-steam)  
28. CnC-DDraw: optional or required? \- Command & Conquer Patch 1.06 \- CNCNZ.com Forums, accessed June 8, 2026, [https://forums.cncnz.com/topic/19254-cnc-ddraw-optional-or-required/](https://forums.cncnz.com/topic/19254-cnc-ddraw-optional-or-required/)  
29. Renderers \- CnC Tools and Resources, accessed June 8, 2026, [https://cc-resource-docs.readthedocs.io/rendererresources/](https://cc-resource-docs.readthedocs.io/rendererresources/)  
30. Enable DirectDraw and use cnc-ddraw, page 1 \- Forum \- GOG.com, accessed June 8, 2026, [https://www.gog.com/forum/tzar\_the\_burden\_of\_the\_crown/enable\_directdraw\_and\_use\_cncddraw](https://www.gog.com/forum/tzar_the_burden_of_the_crown/enable_directdraw_and_use_cncddraw)  
31. How to Install the CnCNet Client on Linux – Articles \- Simon Speich, accessed June 8, 2026, [https://www.speich.net/articles/en/2021/12/19/how-to-install-the-cncnet-client-on-linux/](https://www.speich.net/articles/en/2021/12/19/how-to-install-the-cncnet-client-on-linux/)  
32. Yet another RA2MD.exe resolution guide for fullscreen connoisseurs \- Steam Community, accessed June 8, 2026, [https://steamcommunity.com/sharedfiles/filedetails/?l=polish\&id=3274686523](https://steamcommunity.com/sharedfiles/filedetails/?l=polish&id=3274686523)  
33. A random cnc-ddraw test on Windows NT 4.0 : r/commandandconquer \- Reddit, accessed June 8, 2026, [https://www.reddit.com/r/commandandconquer/comments/1qo7n80/a\_random\_cncddraw\_test\_on\_windows\_nt\_40/](https://www.reddit.com/r/commandandconquer/comments/1qo7n80/a_random_cncddraw_test_on_windows_nt_40/)  
34. Install C\&C: Red Alert 2 Yuri's Revenge (WINE) on Linux | Snap Store \- Snapcraft, accessed June 8, 2026, [https://snapcraft.io/cncra2yr](https://snapcraft.io/cncra2yr)  
35. Guide :: How to play via LAN \- Steam Community, accessed June 8, 2026, [https://steamcommunity.com/sharedfiles/filedetails/?id=3175133785](https://steamcommunity.com/sharedfiles/filedetails/?id=3175133785)  
36. Command & Conquer: Tiberium Sun, Red Alert 2 : r/linux\_gaming \- Reddit, accessed June 8, 2026, [https://www.reddit.com/r/linux\_gaming/comments/3us809/command\_conquer\_tiberium\_sun\_red\_alert\_2/](https://www.reddit.com/r/linux_gaming/comments/3us809/command_conquer_tiberium_sun_red_alert_2/)  
37. Red Alert 2 multiplayer on Windows Vista | by Ayaz Ahmed Khan \- Libel, accessed June 8, 2026, [https://blog.ayaz.pk/red-alert-2-multiplayer-on-windows-vista-1020b61a9304](https://blog.ayaz.pk/red-alert-2-multiplayer-on-windows-vista-1020b61a9304)  
38. Readme \- ipxemu \- SourceForge, accessed June 8, 2026, [https://ipxemu.sourceforge.io/README.txt](https://ipxemu.sourceforge.io/README.txt)  
39. Re: A problem on running Red Alert II in local network | EA Forums \- 7180388, accessed June 8, 2026, [https://forums.ea.com/discussions/command-and-conquer-franchise-en/re-a-problem-on-running-red-alert-ii-in-local-network/7180388](https://forums.ea.com/discussions/command-and-conquer-franchise-en/re-a-problem-on-running-red-alert-ii-in-local-network/7180388)  
40. Using docker with macvlan on Synology NAS \- Roger's Blog, accessed June 8, 2026, [http://blog.differentpla.net/blog/2025/03/08/docker-macvlan/](http://blog.differentpla.net/blog/2025/03/08/docker-macvlan/)  
41. Making Sure Your Synology NAS and OpenClaw Container Can Actually Talk, accessed June 8, 2026, [https://www.richardawilson.com/blog/synology-openclaw-container-networking/](https://www.richardawilson.com/blog/synology-openclaw-container-networking/)  
42. Static IP on Docker containers, accessed June 8, 2026, [https://forums.docker.com/t/static-ip-on-docker-containers/110412](https://forums.docker.com/t/static-ip-on-docker-containers/110412)  
43. Macvlan setup with static ip in docker compose \- Reddit, accessed June 8, 2026, [https://www.reddit.com/r/docker/comments/trfae1/macvlan\_setup\_with\_static\_ip\_in\_docker\_compose/](https://www.reddit.com/r/docker/comments/trfae1/macvlan_setup_with_static_ip_in_docker_compose/)  
44. Docker containers are unable to reach public internet on bridge mode, accessed June 8, 2026, [https://community.synology.com/enu/forum/11/post/142221](https://community.synology.com/enu/forum/11/post/142221)  
45. how i can play lan on red alert 2 \- Support \- CnCNet Community Forums, accessed June 8, 2026, [https://forums.cncnet.org/topic/9789-how-i-can-play-lan-on-red-alert-2/](https://forums.cncnet.org/topic/9789-how-i-can-play-lan-on-red-alert-2/)

[image1]: <data:image/png;base64,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>

[image2]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGEAAAAYCAYAAADqK5OqAAADfklEQVR4Xu2YWahOURTHl3mmUDKPD4pMD6ZwlSQlRaabpCSFiJIHnihvXigPokRKpvJiTF48IEM8KHnwgGQMD4bM63/3Wvesb919vu+cT12p/at/39n/vc6wzzpn73U+okQikUgk8tnGWu9NoRvrCus36zarTWV3MxrznrXG9cUYSiG+tXnAusnayFrFamStYC0XeXayformuT7Qm/WCwliesHpVdlfnBOsbhZ2hDZXdTQyk0NdF2n2k3bY5IgCvg2xjUGi/zrqj6HlbGz1vTHiALN9Zh2S7E+sXq3PWTR0pJEDBA4rjTDReYfKS8Il10nl3WF9N+yLrnGmD8xSOudD5Ct4aHPtfJWEmawxrFGuEyF/LO9Yb095HIWay8T6YbWUshbemNHlJgL/MeTvEV35Ie4nxMEB4r4ynDKKQtLfUcuB59KeWb59nvjdyuOsN5gaFm6cMp3BtQ4wHxrk2Yvw0Pl780sSSMEv8Gc5fLT7mQoAp61jW3cRsCjGxAesFlkkCQGx7bwqYVrt6syDTWaedh6TotWHKmWv6LJi+EHfVeHg78KaVJpaELeJPcv5S8ac433KZQox9usBZ1mDZLpsEgHhdexTM292dV4bYNcCDsG42UPZmY0qytBNfhQQsqIgoAQ6AasGyW3z/Ci4Sf6XzFb0wVFIWLOrXTLueJACbCCSgh+kry1GRR2/qLuPpuoHp1DJAfNXDyu7iYOdNzlsn/gTnY+6HP8f5yheqPg0p9SYBYD8koKfvKAmOM8yblN1QDzxbDaFkxXhBA2X7oQwuDXbc7DxdE6Y5H7U1fKwFHjwFp7zJHGSNdt7fJAGlIoSysV7WUv75qyXB+rGYpxT3a4KdsAZYMED4taoj5Qxrj/OeyS/K2OtOOiBsH5a4IuDm6xqAbSyc9fCY4uMAtyjeZ5Oga2MM+FO9WQvstNWbFPz9zrsgvmU7tSzV+rEOOM9iB1QUmwDr+cW6CNXOj7c21gfviGzjgywWA/L8XPpS2Gmv76D4U4/2YtPG2qAD8op95ivVbkIMfADllaFIRF75mket839mXTJt/H3h49FGAWNB+77zckFtjC/C5xSmDfzi4wo1twVlGm4AfnFSP235G28V+8C6x3pJ4ZwQtn0l5RlJtacdrFVlwPXhQ7MauD7E4Z4g0bHxfKQQ80h+j1d2JxKJRCKRSCQS/wV/AN3iEkpfmqtfAAAAAElFTkSuQmCC>

[image3]: <data:image/png;base64,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>