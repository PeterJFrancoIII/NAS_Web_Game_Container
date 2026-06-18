# **Unlocking Hardware Video Acceleration on Modern Synology DSM: A Kernel-to-Container Architecture Report**

The removal of native video transcoding features, starting with DiskStation Manager (DSM) version 7.2.2 and continuing into version 7.3, has altered the functional landscape for media hosting on Synology NAS hardware.1 By deprecating Advanced Media Extensions (AME) and Video Station, Synology transitioned processing loads for codecs like H.264, HEVC, and VC-1 from server-side computing resources to client end-devices.2  
For users hosting third-party services like Plex, Jellyfin, or Emby inside Docker containers, this transition has introduced major challenges.2 On models such as the "x25" series (e.g., DS225+ and DS425+), which run on the Intel Celeron J4125 processor, the host kernel-space graphics driver stack is stripped of its slice-level hardware encoding entrypoints.2  
Even when the Direct Rendering Infrastructure (DRI) graphics nodes located at /dev/dri are successfully mapped into a container, executing the VA-API verification utility (vainfo) reveals a restricted state 7:  
vainfo: Supported profile and entrypoints  
VAProfileH264Main : VAEntrypointVLD  
VAProfileHEVCMain : VAEntrypointVLD  
The system exposes only video decoding capabilities (VAEntrypointVLD), completely omitting slice-level hardware encoding (VAEntrypointEncSlice and VAEntrypointEncSliceLP).7 Traditional user-defined boot scripts that adjust device permissions via chmod 666 /dev/dri/\* are no longer sufficient because the block resides within the initialization parameters and compilation of the host kernel's i915 driver.6 Resolving this requires reconstructing the host's kernel-space driver configuration and establishing a clean system bridge to the containerized user space.6

## **Host-Level Kernel Reconstruction and Module Intervention**

The absence of hardware encoding profiles on modern DSM installations stems from a crippled host i915 kernel driver module.6 In standard Linux distributions, driver parameters are easily adjusted at boot time through /etc/modprobe.d/ configuration files.12 However, Synology's custom kernel initialization pipeline largely bypasses standard modprobe configuration directories.12 To apply driver options like active Graphics Micro-Controller (GuC) and Media Micro-Controller (HuC) firmware loading, modules must be programmatically unloaded and re-inserted with explicit inline parameters.6

### **The Module Unloading and Re-insertion Sequence**

To replace the default restricted graphics stack without destabilizing the system, active kernel modules must be unloaded in reverse order of their interdependencies, followed by the insertion of a fully featured driver stack.6  
This process requires unloading the active drivers, starting with the core graphics controller (i915), followed by the Kernel Mode Setting helper (drm\_kms\_helper), and finally the Direct Rendering Manager core (drm) 6:

Bash  
sudo rmmod i915  
sudo rmmod drm\_kms\_helper  
sudo rmmod drm

To reconstruct a functional graphics stack with slice-level encoding and high dynamic range (HDR) to standard dynamic range (SDR) hardware tone mapping under kernel version 5.10 (utilized across DSM 7.2.x and 7.3.x), the modified driver modules must be inserted in a precise sequence.6  
Each driver module must be loaded with its prerequisite symbols resolved to avoid kernel symbol reference panic states 6:

Bash  
sudo insmod /volume1/x25\_drivers/dmabuf.ko  
sudo insmod /volume1/x25\_drivers/drm\_buddy.ko  
sudo insmod /volume1/x25\_drivers/drm\_display\_helper.ko  
sudo insmod /volume1/x25\_drivers/drm\_kms\_helper.ko  
sudo insmod /volume1/x25\_drivers/drm\_panel\_orientation\_quirks.ko  
sudo insmod /volume1/x25\_drivers/drm.ko  
sudo insmod /volume1/x25\_drivers/i2c-algo-bit.ko  
sudo insmod /volume1/x25\_drivers/i915-compat.ko  
sudo insmod /volume1/x25\_drivers/intel-gtt.ko  
sudo insmod /volume1/x25\_drivers/ttm.ko  
sudo insmod /volume1/x25\_drivers/i915.ko enable\_guc=3

Passing the module parameter enable\_guc=3 directly during the manual execution of insmod on the i915.ko module is the critical step that unlocks the encoding engine.6

| Module Load Step | Kernel Driver Module | Target Subsystem / Dependency Resolved |
| :---- | :---- | :---- |
| 1 | dmabuf.ko | DMA Buffer Sharing (cross-device buffer sharing infrastructure).6 |
| 2 | drm\_buddy.ko | Memory Buddy Allocator for DRM graphics memory allocation.6 |
| 3 | drm\_display\_helper.ko | Display Core Infrastructure Helpers.6 |
| 4 | drm\_kms\_helper.ko | Kernel Mode Setting (KMS) Display Driver Helpers.6 |
| 5 | drm\_panel\_orientation\_quirks.ko | Resolves panel orientation anomalies on integrated hardware.6 |
| 6 | drm.ko | Core Direct Rendering Manager module.6 |
| 7 | i2c-algo-bit.ko | Core I2C bit-banging algorithm helper for video display data channels.6 |
| 8 | i915-compat.ko | Compatibility layer for Synology i915 driver integrations.6 |
| 9 | intel-gtt.ko | Intel Graphics Translation Table (GTT) driver.6 |
| 10 | ttm.ko | Translation Table Manager (manages GPU-accessible system memory buffers).6 |
| 11 | i915.ko | Core Intel Unified Graphics Driver (must load with enable\_guc=3).6 |

### **GuC/HuC Initialization Parameters**

The enable\_guc parameter manages the relationship between the Intel driver and the low-latency hardware micro-controllers embedded within the integrated GPU (iGPU).12 These controllers manage workloads and accelerate video processing.12

| Parameter Configuration | Underlying Mechanical Operation | Encoding Engine Behavior |
| :---- | :---- | :---- |
| enable\_guc=0 | GuC and HuC micro-controller firmware loading is entirely disabled. | Encoding workloads default to host CPU software execution; low-power video encoding pipelines are locked. |
| enable\_guc=1 | GuC firmware is loaded only for submission scheduling workloads. | The kernel utilizes the GuC scheduler, but advanced slice-level encoding remains unavailable. |
| enable\_guc=2 | HuC firmware is loaded only for media transcode offloading.13 | High-power encoding is enabled, but low-power fixed-function engines remain restricted. |
| enable\_guc=3 | GuC workload submission and HuC media offloading are both active.12 | Unlocks low-power hardware encoding (VDEnc) 15, complete slice-level encoding (VAEntrypointEncSliceLP), and full hardware tone mapping.12 |

### **Resolving GPU Telemetry Failures (intel\_gpu\_top)**

The system monitoring utility intel\_gpu\_top reads performance metrics directly from the host's kernel space.14 On modern DSM versions, calling intel\_gpu\_top may fail or output blank performance metrics even after inserting custom modules. This is caused by restricted access to the GPU debug and performance event structures within the virtual file systems:

* **Metric File Path:** /sys/kernel/debug/dri/0/ 13  
* **Performance Metrics Endpoint:** /sys/class/drm/card0/device/perf\_metrics/

To restore complete telemetry reporting via intel\_gpu\_top without compromising host security, the host's performance query restrictions can be set to allow non-privileged performance queries.10 This is done by writing to the kernel's global paranoid configuration node:

Bash  
sudo sysctl \-w dev.i915.perf\_stream\_paranoid=0

Applying this configuration exposes the raw performance registers to monitoring tools, enabling real-time telemetry updates for GPU core frequency, rendering engines, and video command streamers.

## **Container Integration, Driver Bridging, and User-Space Environments**

To use the restored hardware encoding capabilities inside a containerized environment, the host operating system's driver state must be bridged to the user space of the container.10

### **Driver Selection: iHD vs. i965 vs. Intel QSV**

Choosing the right user-space driver inside the container is critical for stable video acceleration.7 This choice depends on the iGPU generation and the target media framework.21

| Driver / API Layer | Primary Target Hardware | Codec Profile Compatibility | Best Use Cases & Limitations |
| :---- | :---- | :---- | :---- |
| **Intel Media Driver (iHD)** | Intel Gen 8 (Broadwell) and newer (e.g., Celeron J4125 Gemini Lake).8 | Full H.264, HEVC (8-bit and 10-bit), VP9 decoding, and low-power hardware encoding.21 | **Mandatory backend driver for modern media containers.** Required for low-power slice encoding.21 |
| **Legacy Intel VA-API (i965)** | Intel Gen 7 (Skylake) and older platforms.7 | Restricted to H.264; lacks HEVC 10-bit encoding pipelines on modern Celeron chips.21 | Unstable or unsupported on modern configurations; fails to negotiate HEVC 10-bit hardware profiles.21 |
| **Intel Quick Sync Video (QSV)** | All Intel Core/Celeron CPUs featuring Quick Sync hardware.22 | Native H.264, HEVC, and VP9 decoding and encoding; works on top of the iHD backend.13 | **Highly recommended for Plex and Jellyfin.** Offers optimal performance and stable HDR-to-SDR tone mapping.22 |

To force modern media containers to utilize the iHD driver instead of falling back to legacy paths, the following system-level environment variables must be injected into the container's environment 20:

Code snippet  
LIBVA\_DRIVER\_NAME=iHD  
LIBVA\_DRIVERS\_PATH=/usr/lib/x86\_64-linux-gnu/dri/

### **Supplementary Group Mapping and Permission Delegation**

By default, Synology DSM secures the graphics devices at /dev/dri/ using strict file permissions.10 The character device nodes on the host run with the following permissions:

* /dev/dri/card0 (Primary display output node): Owned by root:root with permissions set to 0600\.19  
* /dev/dri/renderD128 (Hardware render node): Owned by root:videodriver with permissions set to 0660\.19

The file permission mask for /dev/dri/renderD128 can be expressed through standard octal notation:  
![][image1]  
For permissions set to 0660, the octal digits are ![][image2] (owner read/write), ![][image3] (group read/write), and ![][image4] (no access for others).  
Rather than running media containers with root privileges (privileged: true), which bypasses container isolation, access can be granted by adding the container's execution user to the host's videodriver group.9 First, find the unique Group ID (GID) of the videodriver group on the host 24:

Bash  
sudo synogroup \--get videodriver

The system output displays the group details 27:  
Group Name: \[videodriver\]  
Group Type:  
Group ID:  
This GID (commonly 937 on DSM 7.2.2+) must be passed directly into the container's runtime variables.24 This maps the container's internal process space to the host group, granting write access to the render node.9

## **Containerized Orchestration Engine (Docker Compose)**

The following docker-compose.yml manifest is a production-grade configuration that binds the restored host DRI nodes to a containerized Jellyfin media server.22 This configuration bypasses the security risks of high-privilege execution models by utilizing direct device mapping and mapping the supplementary videodriver GID.9

YAML  
version: "3.8"

services:  
  jellyfin:  
    image: jellyfin/jellyfin:latest  
    container\_name: jellyfin\_transcode\_prod  
    user: "1026:100" \# Local unprivileged DSM user (UID:GID)  
    group\_add:  
      \- "937" \# Matches the host's videodriver GID to grant access to renderD128 \[9, 25\]  
    environment:  
      \- TZ=America/New\_York  
      \- JELLYFIN\_PublishedServerUrl=192.168.1.50  
      \# Force container to utilize the Intel Media Driver (iHD)   
      \- LIBVA\_DRIVER\_NAME=iHD  
      \- LIBVA\_DRIVERS\_PATH=/usr/lib/x86\_64-linux-gnu/dri/  
      \# Instruct container entrypoint script to include the videodriver group  
      \- GIDLIST=937  
    volumes:  
      \- /volume1/docker/jellyfin/config:/config  
      \- /volume1/docker/jellyfin/cache:/cache  
      \- /volume1/media:/media:ro  
    devices:  
      \# Direct block device mapping of hardware acceleration endpoints \[9, 24\]  
      \- /dev/dri/card0:/dev/dri/card0  
      \- /dev/dri/renderD128:/dev/dri/renderD128  
    security\_opt:  
      \- no-new-privileges:true  
    read\_only: false  
    tmpfs:  
      \- /tmp \# Offloads volatile ffmpeg transcoding states to RAM, reducing write wear on SSD arrays  
    restart: unless-stopped  
    network\_mode: bridge  
    ports:  
      \- "8096:8096"

## **Architecture Variations and Upgrade Resiliency**

Because the graphics driver modifications occur at the host kernel level, any standard DSM update will overwrite these changes.6 To make the solution permanent and resilient to updates, the driver injection process must be automated.  
Two primary methods can be used to achieve update-proof execution: the Automated Community Package method and the Native Boot Injection method.11

### **Method A: The Automated Community Package**

A highly resilient, community-maintained solution is the Transcode\_for\_x25 package created by developer 007revad.3 This package handles driver insertion, unloads default drivers, and acts as a wrapper that automatically starts and stops the correct modules during system state transitions.11

1. Open the **DSM Package Center** and navigate to **Settings \> Package Sources \> Add**.28  
2. Add the custom community repository 28:  
   * **Name:** 007revad  
   * **Location:** https://spkrepo.007daver.workers.dev/  
3. Navigate to the **Community** tab and install the **Transcode Drivers for x25** package.11  
4. Configure elevated execution permissions for the package.28 Go to **Control Panel \> Task Scheduler \> Create \> Scheduled Task \> User-defined script**.29  
5. Set the task to run as the root user, uncheck "Enable", and paste the following permission initialization script 29:  
   Bash  
   file=/var/packages/TranscodeDrivers/target/bin/spk\_su  
   install \-m 4755 \-o root \-D "$file" /opt/sbin/spk\_su  
   chmod a+rx /opt /opt/sbin  
   /opt/sbin/spk\_su TranscodeDrivers  
   rm /var/packages/TranscodeDrivers/installing

6. Select the created task and click **Run**.29 Once executed, the task can be safely deleted, and the package can be started directly within the Package Center.28

### **Method B: Native Boot Injection and BeeStation Driver Extraction**

For systems administrators who prefer to avoid third-party package repositories, the drivers can be securely extracted directly from Synology's official BSM firmware files.4 This keeps the entire driver supply chain within Synology's signed eco-system, mitigating security concerns.30  
The functional i915.ko module can be pulled from a BeeStation firmware bundle 4:

1. Download the official BeeStation Plus .pat file 4: https://global.synologydownload.com/download/BSM/release/1.3/65645/BSM\_BST170-8T\_65645.pat  
2. Decompress the .pat archive using an extraction utility (e.g., Syno\_DSM\_Extractor\_GUI) to locate the core system archive, hda1.tgz.4  
3. Extract hda1.tgz and navigate to /usr/lib/modules inside the extracted structure.4  
4. Copy the fully-featured i915.ko driver and place it on your Synology NAS in a persistent directory, such as /volume1/docker/drivers/i915.ko.4

To automate driver loading at boot, create a shell script at /volume1/docker/drivers/load\_transcode\_drivers.sh:

Bash  
\#\!/bin/bash  
\# \-------------------------------------------------------------------------  
\# Synology DSM 7.2.2+ Hardware Transcoding Driver Loader Script  
\# \-------------------------------------------------------------------------  
set \-e

DRIVER\_DIR="/volume1/docker/drivers"  
DRI\_DIR="/dev/dri"

echo "\[\*\] Unloading official restricted graphics modules..."  
rmmod i915 || true  
rmmod drm\_kms\_helper || true  
rmmod drm || true

echo "\[\*\] Injecting functional modules with GuC/HuC parameters..."  
\# Insert custom i915 stack with low-power encoding activated   
insmod "${DRIVER\_DIR}/dmabuf.ko" || true  
insmod "${DRIVER\_DIR}/drm\_buddy.ko" || true  
insmod "${DRIVER\_DIR}/drm\_display\_helper.ko" || true  
insmod "${DRIVER\_DIR}/drm\_kms\_helper.ko" || true  
insmod "${DRIVER\_DIR}/drm\_panel\_orientation\_quirks.ko" || true  
insmod "${DRIVER\_DIR}/drm.ko" || true  
insmod "${DRIVER\_DIR}/i2c-algo-bit.ko" || true  
insmod "${DRIVER\_DIR}/i915-compat.ko" || true  
insmod "${DRIVER\_DIR}/intel-gtt.ko" || true  
insmod "${DRIVER\_DIR}/ttm.ko" || true  
insmod "${DRIVER\_DIR}/i915.ko" enable\_guc=3 || true

echo "\[\*\] Re-evaluating hardware device node permissions..."  
if; then  
    chown root:937 ${DRI\_DIR}/\* || true  
    chmod 660 ${DRI\_DIR}/renderD128 || true  
    chmod 666 ${DRI\_DIR}/card0 || true  
    echo "\[+\] Hardware encoding modules loaded successfully."  
else  
    echo "\[\!\] Error: /dev/dri directory did not initialize."  
    exit 1  
fi

To schedule this script to run automatically at boot 5:

1. Navigate to **Control Panel \> Task Scheduler**.4  
2. Click **Create \> Triggered Task \> User-defined script**.4  
3. Under the **General** tab:  
   * **Task Name:** Load Transcode Drivers 4  
   * **User:** root (This is mandatory as inserting kernel modules requires administrative privileges) 4  
   * **Event:** Boot-up 4  
4. Under the **Task Settings** tab, enter the execution path 4:  
   Bash  
   bash /volume1/docker/drivers/load\_transcode\_drivers.sh

5. Click **OK** to save the task.31 This configuration will execute automatically on every system start, making your hardware encoding pipeline highly resilient to DSM updates.5

## **Technical Validation and Telemetry Verification**

Once the host driver modules are loaded and the container is running, execute validation tests to confirm that hardware decoding and encoding are fully active.20

### **1\. Verification of Host Kernel Micro-controller Initialization**

To verify that the host kernel has successfully loaded the GuC/HuC micro-controllers, establish an SSH connection to the host and read the system log buffer 13:

Bash  
sudo dmesg | grep \-E "i915|guc|huc"

A successful initialization produces log entries similar to the following:  
\[ 8.102456\] i915 0000:00:02.0: \[drm\] Injected functional i915 driver.  
\[ 8.140212\] i915 0000:00:02.0: \[drm\] GuC firmware i915/kbl\_guc\_33.0.0.bin version 33.0 submission: enabled  
\[ 8.140218\] i915 0000:00:02.0: \[drm\] HuC firmware i915/kbl\_huc\_4.0.0.bin version 4.0 authenticated: yes  
To confirm that GuC workload submission is active, check the kernel debug filesystem 13:

Bash  
sudo cat /sys/kernel/debug/dri/0/gt/uc/guc\_info

Look for the status line in the output:  
Submission status: GUC\_SUBMISSION\_ACTIVE

### **2\. Verification of Container User-Space VA-API Entrypoints**

To verify that the containerized application has access to the restored hardware encoding pipelines, execute vainfo inside the running container.20 Run the following command from the host terminal:

Bash  
docker exec \-it jellyfin\_transcode\_prod \\  
  env LIBVA\_DRIVER\_NAME=iHD vainfo \--display drm \--device /dev/dri/renderD128

The output should confirm that the iHD driver is active and list the essential entrypoints 8:  
libva info: VA-API version 1.21.0  
libva info: User environment variable requested driver 'iHD'  
libva info: Trying to open /usr/lib/x86\_64-linux-gnu/dri/iHD\_drv\_video.so  
libva info: Found init function \_\_vaDriverInit\_1\_21  
libva info: va\_openDriver() returns 0  
vainfo: Supported profile and entrypoints  
VAProfileH264Main : VAEntrypointVLD  
VAProfileH264Main : VAEntrypointEncSlice  
VAProfileH264Main : VAEntrypointEncSliceLP  
VAProfileH264High : VAEntrypointVLD  
VAProfileH264High : VAEntrypointEncSlice  
VAProfileH264High : VAEntrypointEncSliceLP  
VAProfileHEVCMain : VAEntrypointVLD  
VAProfileHEVCMain : VAEntrypointEncSlice  
VAProfileHEVCMain10 : VAEntrypointVLD  
VAProfileHEVCMain10 : VAEntrypointEncSlice  
VAProfileVP9Profile0 : VAEntrypointVLD  
VAProfileVP9Profile0 : VAEntrypointEncSlice  
The presence of VAEntrypointEncSlice and VAEntrypointEncSliceLP confirms that the slice-level hardware encoding engines are successfully unlocked and ready for use.7

### **3\. Pipeline Throughput and Efficiency**

Transcoding throughput ![][image5] in frames per second (FPS) can be modeled as a function of the hardware-accelerated processing time per frame ![][image6]:  
![][image7]  
Where ![][image8] is decode latency, ![][image9] is encode latency, and ![][image10] is scaling/processing latency. In a software fallback pipeline, the host CPU latency escalates exponentially due to the lack of dedicated fixed-function hardware pipelines:  
![][image11]  
By restoring the functional i915 kernel driver stack, the host CPU is freed from software fallback encoding.4 Workloads are handled directly by the Intel UHD Graphics 600 fixed-function hardware pipelines, restoring native, highly efficient multi-stream video transcoding to your Synology NAS.4

#### **Works cited**

1. DS Video with DSM 7.2.2? \- Synology Community, accessed June 9, 2026, [https://community.synology.com/enu/forum/1/post/189602](https://community.synology.com/enu/forum/1/post/189602)  
2. DSM 7.3 Hardware Transcoding \- Synology \- Emby Community, accessed June 9, 2026, [https://emby.media/community/topic/143176-dsm-73-hardware-transcoding/](https://emby.media/community/topic/143176-dsm-73-hardware-transcoding/)  
3. Does Synology DSM 7.2.2-72806 remove HW Transcoding in Plex? \- Reddit, accessed June 9, 2026, [https://www.reddit.com/r/PleX/comments/1nqt02q/does\_synology\_dsm\_72272806\_remove\_hw\_transcoding/](https://www.reddit.com/r/PleX/comments/1nqt02q/does_synology_dsm_72272806_remove_hw_transcoding/)  
4. \[Discovery\] Unlocking Native Hardware Transcoding on Synology 25-Series (J4125 Models)\!, accessed June 9, 2026, [https://community.synology.com/enu/forum/1/post/194638](https://community.synology.com/enu/forum/1/post/194638)  
5. \[Discovery\] Unlocking Native Hardware Transcoding on Synology 25-Series (J4125 Models)\!, accessed June 9, 2026, [https://community.synology.com/enu/forum/1/post/194638?reply=530999](https://community.synology.com/enu/forum/1/post/194638?reply=530999)  
6. Unlocking PLEX HW transcoding on X25 Synology models \- Blackvoid, accessed June 9, 2026, [https://www.blackvoid.club/unlocking-plex-hw-transcoding-on-x25-synology-models/](https://www.blackvoid.club/unlocking-plex-hw-transcoding-on-x25-synology-models/)  
7. Hardware video acceleration \- ArchWiki, accessed June 9, 2026, [https://wiki.archlinux.org/title/Hardware\_video\_acceleration](https://wiki.archlinux.org/title/Hardware_video_acceleration)  
8. Lastest ffmpeg6 not work with QSV · Issue \#6174 · SynoCommunity/spksrc \- GitHub, accessed June 9, 2026, [https://github.com/SynoCommunity/spksrc/issues/6174](https://github.com/SynoCommunity/spksrc/issues/6174)  
9. Synology \> Docker \> Jellyfin \- How to enable hardware acceleration/transcoding? \- Reddit, accessed June 9, 2026, [https://www.reddit.com/r/synology/comments/17j7u6d/synology\_docker\_jellyfin\_how\_to\_enable\_hardware/](https://www.reddit.com/r/synology/comments/17j7u6d/synology_docker_jellyfin_how_to_enable_hardware/)  
10. Hardware Transcoding on Synology Docker without Privileged Mode, accessed June 9, 2026, [https://ryanbritton.com/2022/05/hardware-transcoding-on-synology-docker-without-privileged-mode/](https://ryanbritton.com/2022/05/hardware-transcoding-on-synology-docker-without-privileged-mode/)  
11. 007revad/Transcode\_for\_x25: Installs the modules needed for transcoding in DS425+ and DS225+ \- GitHub, accessed June 9, 2026, [https://github.com/007revad/Transcode\_for\_x25](https://github.com/007revad/Transcode_for_x25)  
12. i915 guc/huc firmware in DSM 7.1.1 : r/jellyfin \- Reddit, accessed June 9, 2026, [https://www.reddit.com/r/jellyfin/comments/102yzi1/i915\_guchuc\_firmware\_in\_dsm\_711/](https://www.reddit.com/r/jellyfin/comments/102yzi1/i915_guchuc_firmware_in_dsm_711/)  
13. Intel GPU | Jellyfin, accessed June 9, 2026, [https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/intel/](https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/intel/)  
14. Hardware transcoding doesn't seems to work \- General/Windows \- Emby Community, accessed June 9, 2026, [https://emby.media/community/topic/128477-hardware-transcoding-doesnt-seems-to-work/](https://emby.media/community/topic/128477-hardware-transcoding-doesnt-seems-to-work/)  
15. Intel Graphics Media Driver to support hardware decode, encode and video processing. \- GitHub, accessed June 9, 2026, [https://github.com/intel/media-driver](https://github.com/intel/media-driver)  
16. unknown parameter 'i915' ignored \- Fedora Discussion, accessed June 9, 2026, [https://discussion.fedoraproject.org/t/i915-unknown-parameter-i915-ignored/76001](https://discussion.fedoraproject.org/t/i915-unknown-parameter-i915-ignored/76001)  
17. FAQ \- Xpenology, accessed June 9, 2026, [https://xpenology.tech/faq/](https://xpenology.tech/faq/)  
18. Proxmox VE 9.2: Windows 11 vGPU (VT-d) Passthrough with Intel Alder Lake, accessed June 9, 2026, [https://www.derekseaman.com/2024/07/proxmox-ve-8-2-windows-11-vgpu-vt-d-passthrough-with-intel-alder-lake.html](https://www.derekseaman.com/2024/07/proxmox-ve-8-2-windows-11-vgpu-vt-d-passthrough-with-intel-alder-lake.html)  
19. Transcoding failure\!\! \- Synology \- Emby Community, accessed June 9, 2026, [https://emby.media/community/topic/145004-transcoding-failure/](https://emby.media/community/topic/145004-transcoding-failure/)  
20. It's slow : r/jellyfin \- Reddit, accessed June 9, 2026, [https://www.reddit.com/r/jellyfin/comments/1qsc5op/its\_slow/](https://www.reddit.com/r/jellyfin/comments/1qsc5op/its_slow/)  
21. Use i965 HW Encoding/Decoding Driver Instead of iHD : r/Tdarr \- Reddit, accessed June 9, 2026, [https://www.reddit.com/r/Tdarr/comments/hy7slr/use\_i965\_hw\_encodingdecoding\_driver\_instead\_of\_ihd/](https://www.reddit.com/r/Tdarr/comments/hy7slr/use_i965_hw_encodingdecoding_driver_instead_of_ihd/)  
22. Jellyfin with HW transcoding : r/synology \- Reddit, accessed June 9, 2026, [https://www.reddit.com/r/synology/comments/1f303tj/jellyfin\_with\_hw\_transcoding/](https://www.reddit.com/r/synology/comments/1f303tj/jellyfin_with_hw_transcoding/)  
23. How to Install Jellyfin With Hardware Transcoding on Your Synology NAS \- Marius Hosting, accessed June 9, 2026, [https://mariushosting.com/how-to-install-jellyfin-with-hardware-transcoding-on-your-synology-nas/](https://mariushosting.com/how-to-install-jellyfin-with-hardware-transcoding-on-your-synology-nas/)  
24. Emby with Hardware Transcoding in Docker on Synology DSM 7.2 ..., accessed June 9, 2026, [https://joshmccarty.com/emby-with-hardware-transcoding-in-docker-on-synology-dsm-7-2/](https://joshmccarty.com/emby-with-hardware-transcoding-in-docker-on-synology-dsm-7-2/)  
25. \[Help\] HandBrake Docker on DS224+ not detecting QSV despite /dev/dri mount : r/synology, accessed June 9, 2026, [https://www.reddit.com/r/synology/comments/1o5hyg0/help\_handbrake\_docker\_on\_ds224\_not\_detecting\_qsv/](https://www.reddit.com/r/synology/comments/1o5hyg0/help_handbrake_docker_on_ds224_not_detecting_qsv/)  
26. Hardware transcoding not working \- Synology \- Emby Community, accessed June 9, 2026, [https://emby.media/community/topic/134161-hardware-transcoding-not-working/](https://emby.media/community/topic/134161-hardware-transcoding-not-working/)  
27. HW Transcoding on DS1819+ \- Synology \- Emby Community, accessed June 9, 2026, [https://emby.media/community/topic/138232-hw-transcoding-on-ds1819/](https://emby.media/community/topic/138232-hw-transcoding-on-ds1819/)  
28. 225+ or 425+ Owners \- Plex HW Transcoding. | Page 5 | SynoForum.com \- The Unofficial Synology Forum, accessed June 9, 2026, [https://www.synoforum.com/threads/225-or-425-owners-plex-hw-transcoding.15094/page-5](https://www.synoforum.com/threads/225-or-425-owners-plex-hw-transcoding.15094/page-5)  
29. Transcode\_for\_x25/set\_package\_permissions.md at main \- GitHub, accessed June 9, 2026, [https://github.com/007revad/Transcode\_for\_x25/blob/main/set\_package\_permissions.md](https://github.com/007revad/Transcode_for_x25/blob/main/set_package_permissions.md)  
30. Someone finally cracked HW transcoding on x25 series : r/synology \- Reddit, accessed June 9, 2026, [https://www.reddit.com/r/synology/comments/1o15zz9/someone\_finally\_cracked\_hw\_transcoding\_on\_x25/](https://www.reddit.com/r/synology/comments/1o15zz9/someone_finally_cracked_hw_transcoding_on_x25/)  
31. \[Discovery\] Unlocking Native Hardware Transcoding on Synology 25-Series (J4125 Models)\!, accessed June 9, 2026, [https://community.synology.com/enu/forum/1/post/194638?reply=528333](https://community.synology.com/enu/forum/1/post/194638?reply=528333)  
32. Transcode\_for\_x25/how\_to\_schedule.md at main \- GitHub, accessed June 9, 2026, [https://github.com/007revad/Transcode\_for\_x25/blob/main/how\_to\_schedule.md](https://github.com/007revad/Transcode_for_x25/blob/main/how_to_schedule.md)

[image1]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAmwAAABWCAYAAABy68rHAAAD/UlEQVR4Xu3dT8hlYxwH8IdRQoSFRglFhAU1GzUpO5YoUkoWVhY2MhZ2ykIWZmFhZ3ajyYKUlCyQ/NkohWxMQgyhMEj+PU/nnO7z/txz/7z3nvuemfv51Ldz7+85977nzmx+nXOe56QEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMBp6ZOcfTkn4wAAAOPwY7v9d0cVAIDReS0WAAAYlxOxAADAOLzQbssl0dfrAQAAxuHRduseNgAAAAAAAAAAAAAA2ELHc77M+TrnmzbfLpjymTE4MxYAAE4nZQZoydE4MMPdafK5+8LYpr3YbhedyXogFgAATgVd83V2HJjjkbR4ozS032Khx/5YAAC2w+Gcv1PTvPye80P7eizNzDw3psnxXhbG5jmrzdAuTs3xfR7ql+S8FWp9nk+nzv8JADCAac3Aq1NqY/VVGneTeUv1etoxdrULe9LxXFQA2GLTmp1Pp9TGrPsNL8WBPXZD2nm5tvs3vTPnzVCb5bqcc3KujQMAwHYoDcO7U2p3hNqY3ZUmTdu5YWwvnZeaY7qqfV83Z7/mvJdzdVXrU860HY9FAGB71E3O+Tn/5Nw2GR5UaUJm5aPJrnOVs1ld07aqZ3J+Tuv5rmfT+o4LANhC96bhGonH03Df3eeL1PzNMpFit/7Iubx9vY7jL5M5Ck0bALArpYE4EotLmNeAzBsfQtcY3Rrqi5h1Vq2vfkbqH/szvP8l56JQAwCYqa/RKG7O+SDn46pW9n8651hqzhzVZ42+y3kqNUuDdGZ9/1DK5d0yaWI3yvHG5TdWEX//g+E9AMBcsaGo1WPv5zyQmpmKZV2x8ninot7nr3b7cFWb9f1DWeVvls8eicXsw5zPYnEB9+Q8Ub1f5dgAAP7nnep1fSatVtfKOmGPpea+uM60zwzpZCws6YrUHHNZUPfJnJdTMwHj+pyfqv2WcUHOGzmH4gAAwKrqZuvt1CwAe037/rl2W/bpZph2lxLLrMjOJhu28tSAeqHZddrk7wAAWEppgMpaYrWy9EefS9vtvh3V4ZWG6vZYXMCVsdDjRM79sQgAwGK+j4UFedQTAMAGvJKWf+h7uaes7548AADWLK5zNku5/64sUdI1a4d3DgMAsG5d47XbAAAAAAAAAAAAAAAAW6A8QmoRD8UCAADjYnYoAMAeqB9SP4+GDQBgw8ql0GOxOIOGDQBgD9RN2KGedDRsAAB7oEwkOBCLU9yUmobtYBwAAGBYpREDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIDl/QeQfdDpXRWc1wAAAABJRU5ErkJggg==>

[image2]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADcAAAAZCAYAAACVfbYAAAABZUlEQVR4Xu2WvUrEQBSFLyJq5QMsImglCILNtmIhYiG+gBY+hyDY2m1hJf5hIVhY+waiovgOgoV/YKGF/+fsTMjNNckSXdxNmA8O5J47A3M2s5MRCQQCgdasQB9es6ZXat6gTf/cD31CA3G7vDxAd6puQF9QXXmlZERckGHjT5g6lwXoCFq2jQ5zIi4c6YNmVK8lc+ImT/t6A7qI2x2Ha6MOoClo3NfcmrnwV7CvnPW5qouyn6M9aBfahrbEHRA8HPKIwq0pb9R7Q8r7AQfcGo97XDMJnRnvP4nCWejdWDOCJw0HzNuGYlXcNu3WcGl+E26LzKaC26FIuPWCGnTTMjmV9HXmhluS7Oaiei4art2MSfo66e1YU8MBnKx5lOTVhuH+csC0gxfoWNW8hqUFTlCD3iV+xYfJdhOG64ZPw7W4Nb6Ku3r1JNu/g+EurVkVGO7KmlXgWdx/8B56gnqT7UAgEKg43z/5WziwEIQRAAAAAElFTkSuQmCC>

[image3]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADcAAAAZCAYAAACVfbYAAAABfUlEQVR4Xu2Wu0oEMRSGD4KXQvYBRAS1EQRLG0GxEBEUX0DxAj6CNla2YmNhJd6wECwsrHwDEdGXEC1WFG0svP9nkyFnzs5kWYsZIvngg5z/ZCCZzYYhikQikcaswy/rpOoFzQfcteN2+A07XDtcnuCjqLfhDxwWWZD0ktlIj8qHVO1lFp7BJd0omUsym2Pa4IToNWSKzMPjtt6BN65dOrw29gSOwUFb89H0wm9B/+RcX4u6WY49HsFDuA/3yFwQfDn4SDa3IbI+m3WLrA6eUFUZn/GEBTJz3mC/yIsk2ZyGswcdJvBNwxNmdMMySu7N8Nvlua2uXRi+zWXlNfhY5DbJHB3Z5/GWqPPYbNKKeSyXK8pep3dz85TfnNMBmbnTOiyAAcpeJ2cHOpTwBH5Y8kz1nzYr8EVlRcL/+QtR82dY1oZTdMFPcj/xabpdoxPe67AE7sis8Z3Mp1dLuv03bsV4TYyD5xUuwmW4CkdS3YA5J3dcvTdTJBKJ/Ft+Aca1X7bDfw6tAAAAAElFTkSuQmCC>

[image4]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADcAAAAZCAYAAACVfbYAAAABZklEQVR4Xu2Wr0sEURDHx6QW8eoFwSYmQTDYDIcYxCCYNIjFf0KbReuZ/IEiiBjMghgtiqAgWuyC3BkUxCDod/btnrPDzsohvOPJ+8AHdr7z9naH27csUSQSiZSzAl/hO1xSvaC5h2eivoMXog6WPvilQ3JZvw5D44bs4bZ1aDEDT+CibnQYHsIarijPMUVu0URab8Lrn3bHsYaw8hY1cgsGRMb1lajb5aDEfbgHd+EO3ILdyVk21hBW3oKbzyobFMdz8BM+wmGR+8QawsoTxsg1p3UjpQc+iZrXdonaF9YQVp7Aj4XZTHkRx7+tzVhvU37Vl/FGxdfm7EGHGQtUfBIzr+o6PFWZL3hrFN0nZ6M6lPCCIZXxvzUp6jVy+7IiMt/wfS6LeiPNSqmSe2Fkz+9xvp2D+yM69EQvuetfwlv4QX/c/7PwSNT84/L7LmjOYUPUPNy4qIOHhzuETbiqepFIJPL/+QaSSmGMezJ+/QAAAABJRU5ErkJggg==>

[image5]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAA8AAAAZCAYAAADuWXTMAAAAlUlEQVR4XmNgGLlgMxD/JwGjAJBAGBYxdIUa6GJCDBCbkQETA0TRBTRxEHiEzNkKxIzIAkBQwADR7I8mzgbEfcgC+cgcKHjPgOlkEBAAYnF0QXSAzb9EAWYGiMYz6BLEgHIGiGZvdAliwGcGMp0MAmT7FxQVZPt3NgNEcwKaOE4QBMTfGCBx+xaKQf7+xUCm80fB8AIAG+0tbGX6R2IAAAAASUVORK5CYII=>

[image6]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABEAAAAZCAYAAADXPsWXAAAA1ElEQVR4Xu2SOwrCQBiEfx+FrZVWVrYiWFh5AkGsPYQg4jEsbG3tBG9gm8oTeAnFQkQLH/O7u7AMickqiIUffJCdSaZYIvLnK5zghsNQ7nDEYQhNMSN5LrLQgV24FjPSs+cgxnAiZmBnz+pb6MiQwxhqHDgaYkZyXBBXuIBTLpSVmJFXVOEB9mGBuic6sOeQmFkT0RG9XEfkPSva+8aiRd0+X/zCI/Fjh16UvnSGReocqSNplOGNw1D051tyGMoWtjnMSglW5MP7OMIBnHMRSouD3+UBucspI2geIBQAAAAASUVORK5CYII=>

[image7]: <data:image/png;base64,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>

[image8]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADMAAAAZCAYAAACclhZ6AAABq0lEQVR4Xu2WzSsGURTGj48UZW1loWRFspFkr0hW/gELViJRyk42SvkHWNnJgjUbXwsfeSMpsRgf2YiFhc8Fz+mcac7cXmN6h8XU/dXTnPvcO/eZ08y87xB5PB6P8gIduGZe+YLGXDOPtJI0U+5O5IkuqAfaIGmmT8e5ZByaIGnkUcesXMPNjLhmHmkhaabMnTBMkaz5z0fwTzJWSTb5jWPKGJSCzBncyJNrFuGIMgalIHMGN8M/AiG7pj6E1qAr6JziQa/QJPRJ0SNaRbLfLPQBVajfQfKHPAMV1AtJytiGFqA3qNn4P8LhjVq/G59Dhs34jqKgZ6hN627oUmveq1rrG6geqlE/pB3a1zopYw5aN3NpXgWaJ1nI3Vca3z05oCiI526NeFyrR5dFaM/xwnXu+oDiGQ8UzygZPtl+EQRQr9bFNnbvQMgSdOZ4tpmkjIFoKhun0KgZ86PVr/UKxd+zCz3yBTQZn9fw3bZNDkI7Widl8CfWtZlbNnVJbJEE88UGJBfFnzzMNMk7dq/jkBOStZvGayBZyxc3ZHwmKaNTx3xenXoej8cT5xtwk3fZ+NnAJgAAAABJRU5ErkJggg==>

[image9]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADMAAAAZCAYAAACclhZ6AAABwklEQVR4Xu2WyytFURTGl0eKMjYyUDIimUgyVyQjkWJgwEgkSpnJRCn/ACMzDBhT8iqvyCOPGFyPTOSRgeeAb7XWcdfZuiVXOLW/+nXX/tY+j++cfc49RF5eXl6qB7DmmlHVG+h0zSiqmCRMqtuIkipAFZghCVOj40iqC3STBLnWMRNpcZh214yiikjCpLiNX1YvyXkktcwnSXbyH7RJSYbhIDeu+UfaoB8Iwy+BQEumfgQ94JVkGTaQzJ8AW2AOrHzMJsrQ/gB4AWnql5H8IfeTbGe1DqbACdincJgFMAyeQKHxE4oPnq/1s/HvQYnWleBY62YKL0u3ztT6DOSCLPUDlYJVrTlIm+ldUDzMIJg2vS89CkMkEzl9uvHZOzcEO2sEh8Ek42eb2moELDteMM+dH6N4GO5d0efjf0uJNq4Hu2YczHPvQKBRsOd4Noz96oiBaq25VxdvJadxCj9LR/rbBA6MbwNwXWDGvD3fbTunBSxqvQM6TI+Xdq3W/Il1anpjpv6W+kieo0sd8xK7Jfla4BPhFwTXd9pnbZNc4Vnj5ZHsh0+u1fiseZJwfLFiJMH5s4pVrmPeLkc9Ly8vr7DeAcACddDIXTj8AAAAAElFTkSuQmCC>

[image10]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACYAAAAZCAYAAABdEVzWAAABcklEQVR4Xu2Vuy9EQRTGj0cnSIj4A2hFLxrRSVRKiUdLiIhCqaNQqxSLRKXQaAgRkUhEp9J5JES8ovCKBN+3c8Y9ZknW7iZ3i/klv9wz352ZnJ27d1ckEolkeYaHYVgOfMKJMEybdnGNVYY30qIT9sAtcY316jh1JuGUuKbudEzLBjY2FoZp0yausYrwRglYFrd3QaxJEYvzoOC9ufA+DEtIUY3xBfDs63UJzsF1+bn5GVyAe7BDs4y4l4ZzdzXz2LVN4g5hBh6b/Fe4sFXrtyD38F+BnMBRrafhrNaXsFnrW9ilNbH72PoA9ptxDvPiFrzCapOfas6mGjTj+K8f4T64A9/hgMl9My1aX6gPcNVP+g814t7UcUk257Xqe0YC826tj+BgcI/wRO2JFQwfj4enSbbhisk5p15yH/sw3NCxvcfTbDTjEVPnDTe+gVdwyOQZ+ALPTbYIn+A1rIMfsFYzfucek6nZD8dHuWmySCRCvgC4mFra7RsDKQAAAABJRU5ErkJggg==>

[image11]: <data:image/png;base64,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>