# **Diagnostic Analysis and Engineering Remediation of WebRTC Transport Failures on Synology Docker Stacks**

## **Architectural Topology and Port Allocation**

To diagnose the WebRTC transport failure within the containerized cloud gaming pipeline, it is essential to map the unified network topology. The system operates on a dual-protocol split architecture on a Synology DS225+ NAS running DSM 7.x, serving remote client browsers over the public internet.1

                                  \+---------------------------------------+  
                                  |         Remote Client Browser         |  
                                  |  (ultra-play.js v71, Receive-Only)    |  
                                  \+---------------------------------------+  
                                        /             |             \\  
                          (TCP 6081\)   /              |              \\ (UDP/TCP 62011\)  
                                      /               |               \\  
                                     v                |                v  
                 \+-----------------------+            |            \+---------------+  
                 |  Synology Host Port   |            |            |  CoTURN Relay |  
                 |  Forwarding (Router)  |            |            |  (RA2\_Coturn) |  
                 \+-----------------------+            |            \+---------------+  
                             |                        |                    |  
                  (WSS /webrtc-signal)                |                    | (UDP 62012-62014)  
                             v                        |                    v  
               \+---------------------------+          |          \+-------------------+  
               |   ra2-stream-gateway.py   |          |          |  GStreamer Socket |  
               |     (Signaling Proxy)     |          |          |  (webrtcbin)      |  
               \+---------------------------+          |          \+-------------------+  
                             |                        |                    ^  
                      (Local IPC WSS)                 |                    |  
                             v                        |                    |  
               \+---------------------------+          |                    |  
               |      webrtc-media.py      |          |                    |  
               |    (Bridge controller)    |          |                    |  
               \+---------------------------+          |                    |  
                             |                        |                    |  
                      (Unix Pipe/gdbus)               |                    |  
                             v                        |                    |  
               \+---------------------------+          |                    |  
               |   webrtc-media-helper.c   |          |                    |  
               |   (GStreamer Pipeline)    | \<--------+--------------------+  
               \+---------------------------+    (Direct WebRTC UDP 62001-62010)

The unified registry of all ports, container configurations, and physical interfaces must be maintained precisely to prevent state machine mismatches.

### **Table 1: System Port Registry and Translation Schema**

| Component Name | Container Port | Host Bound Port | Protocol | Network Namespace | Functionality |
| :---- | :---- | :---- | :---- | :---- | :---- |
| **Reverse Proxy** | N/A | 6081 | TCP | Host Namespace | HTTPS/WSS External Entry Point 1 |
| **ra2-stream-gateway** | 6081 | 6081 | TCP | Bridge / Player-1 | Websocket Signaling Proxy 3 |
| **webrtc-media.py** | 6090 | Internal Only | TCP | Player-1 Localhost | Signaling Endpoint & JSON Bridge |
| **webrtc-media-helper** | Dynamic | 62001–62010 | UDP & TCP | Player-1 Localhost | GStreamer webrtcbin Media Ports |
| **RA2\_Coturn (STUN)** | 62011 | 62011 | UDP & TCP | Shared (Player-1) | STUN Binding Request Handler |
| **RA2\_Coturn (TURN)** | 62011 | 62011 | UDP & TCP | Shared (Player-1) | TURN Allocation & Control |
| **Coturn Relay Pool** | Dynamic | 62012–62014 | UDP | Shared (Player-1) | TURN Relayed Data Allocations |

## **Diagnostic Findings and Root Cause Analysis**

An analysis of the system architecture, network constraints, and client-side behavior reveals why the UDP/WebRTC video transport fails and falls back to WSS. The failure is driven by three distinct network and protocol anomalies, ranked below by their structural likelihood and supported by a continuous technical evidence chain.

### **Table 2: Diagnostic Severity Matrix**

| Severity Level | Core Vector | Impact on Connection State | Remediation Path |
| :---- | :---- | :---- | :---- |
| **Critical** | Synology Docker Bridge UDP Source IP Masquerading | Induces false-positive completed state on server while black-holing media to the client.6 | Transition container network stack to Host Network Mode.3 |
| **High** | Client mDNS Candidate Masking (No getUserMedia) | Strips browser of host candidate exposure, forcing total reliance on STUN/TURN.9 | Enable secure, authenticated Coturn TCP/UDP Fallback pathways.10 |
| **High** | Dynamic IP Coturn Allocation Configuration Mismatch | Invalidates the XOR-RELAYED-ADDRESS payload returned to the client browser.5 | Configure dynamic DDNS resolution scripts to rewrite external-ip.12 |
| **Moderate** | Split-Horizon / Hairpin Router Routing Block | Blocks direct loopback testing on local subnets via the public DDNS address.9 | Implement split-horizon DNS or enforce TURN routing for same-subnet tests.9 |

### **Root Cause 1: Synology Docker Bridge Network UDP Source IP Masquerading**

The primary technical anomaly is the asymmetric state mismatch where the server logs show ice-connection-state=3 (completed) and peer-connection-state=2 (connected), while the remote browser client never receives media, fails to trigger the ontrack event, and remains stuck in the WSS fallback loop.16  
This behavior is caused by the custom iptables and userland NAT proxy (docker-proxy) implementation inside Synology's modified Docker runtime.6 When the container stack is deployed in bridge network mode, any inbound UDP connection through a published port range (e.g., 62001–62020) has its source IP address rewritten to the bridge default gateway IP (typically 172.17.0.1 or 172.22.0.1).6

Remote Client (108.2.161.76)   
       |  
       v  Source: 108.2.161.76  
\+--------------------------------------------------------+  
| Synology Physical Interface (192.168.0.193)            |  
|       |                                                |  
|       v  (NAT/Userland Proxy Masquerades Source IP)    |  
|          Source IP rewritten to 172.22.0.1             |  
|       |                                                |  
|       v  Source: 172.22.0.1     |  
| \+----------------------------------------------------+ |  
| | Docker Bridge Namespace (Player-1)                 | |  
| |       |                                            | |  
| |       v  GStreamer / libnice perceives client at   | |  
| |          local gateway IP: 172.22.0.1              | |  
| |                                                    | |  
| |  State transitions to CONNECTED / COMPLETED        | |  
| |       |                                            | |  
| |       v  SRTP Video Packets sent to 172.22.0.1     | |  
| |                                                    | |  
| |  (Packets are black-holed at the bridge gateway,   | |  
| |   never routed back to Client WAN IP)              | |  
| \+----------------------------------------------------+ |  
\+--------------------------------------------------------+

When the client browser sends an initial STUN binding request over UDP, the packet crosses the router's port forwarding and reaches the Synology host.20 However, the NAT bridge proxy rewrites the source address to 172.22.0.1.6 GStreamer’s underlying ICE agent (libnice) receives the STUN packet and registers a successful connection check on the candidate pair corresponding to the gateway address.21  
Because a valid bidirectional exchange occurred within the local network space, GStreamer's state machine transitions to completed and connected.16 The GStreamer pipeline then begins transmitting secure real-time transport (SRTP) video frames back to 172.22.0.1.22  
However, these UDP media packets are black-holed at the bridge interface.24 The host's connection tracking table cannot match these outbound UDP packets back to the remote client's public IP and port, as the initial translation was asymmetric.6 The remote client's browser, waiting on the public WAN interface, receives no media packets, fails to trigger the DTLS handshake, and ultimately defaults to the WSS transport layer.17

### **Root Cause 2: Browser mDNS Candidate Masking on Receive-Only Streams**

The second failure vector is the browser's candidate gathering behavior under different privacy contexts. The server logs consistently show the warning:  
\[webrtc\] WARN: client sent no usable ICE (need srflx/relay, not mDNS.local)  
Modern web browsers implement multicast DNS (mDNS) candidate masking to prevent the exposure of private LAN IP addresses, which can be used for device fingerprinting and cross-site tracking.9 The browser replaces local IPv4 host candidates with dynamically generated UUIDs ending in .local (e.g., 3f8e561d-789a-4bcf-8c23-e5173dfd9f2a.local).9  
Under the standard WebRTC protocol, browsers only reveal raw local IP addresses in candidate lists if the user has granted explicit media capture permissions via getUserMedia.9 However, the RA2 cloud gaming player is a receive-only client.29 It consumes video and audio from GStreamer and sends user input back over WSS; it does not record local camera feeds or microphone audio.29  
Because the web application does not call getUserMedia, the browser executes under a restricted privacy context, exposing *only* mDNS-masked host candidates.9  
GStreamer's standard libnice implementation does not natively resolve mDNS .local addresses across routed boundaries or inside containerized networks.9 Any mDNS candidate received via trickle ICE signaling is dropped by webrtcbin as unresolvable.32  
Consequently, the entire peer-to-peer connection depends on the client's ability to gather and negotiate Server Reflexive (typ srflx) or Relayed (typ relay) candidates.9

### **Root Cause 3: Dynamic IP Configuration and Masquerading on Coturn NAT Traversal**

Because host candidates are masked by mDNS, the connection must fall back to STUN or TURN.9 However, STUN binding checks (typ srflx) are frequently blocked by symmetric NAT routers and stateful firewalls on the client side.34 On symmetric NAT networks, the router randomizes the external source port for every unique destination IP, making direct UDP hole-punching mathematically impossible.20  
Under these conditions, a TURN relay server is required.34 While Coturn is deployed on port 62011, it fails to relay media due to two primary configuration errors:

1. **The Shared Network Namespace Masquerading Loop:** Even though RA2\_Coturn shares the network namespace of the player container, it still operates behind the Synology Docker bridge.3 Consequently, any allocation request from a remote client reaching Coturn is also subjected to the source IP rewrite to 172.22.0.1.6 Coturn cannot validate or bind relay allocations when the incoming control packets appear to originate from the internal bridge gateway rather than the client's actual WAN IP.6  
2. **Dynamic public-ip NAT Translation Constraints:** In a typical home router deployment behind a dynamic public IP (DDNS: peterjfrancoiii2.synology.me), the WAN IP is subject to periodic rotation by the ISP.12 Coturn requires the external-ip parameter to be statically defined in turnserver.conf to rewrite the XOR-RELAYED-ADDRESS attribute in its allocation responses.2 If Coturn is configured without this option, or with a stale IP, it returns private IP candidates (e.g., 172.22.0.x or 192.168.0.x) to the remote browser.38 The browser cannot route media to these internal addresses, causing the TURN allocation to fail.5

### **Analyzing the 881-Byte SDP Answer Anomaly**

The representative log pattern notes an 881-byte remote answer SDP:  
\[webrtc\] remote answer applied (881 bytes, ICE:???)  
A standard WebRTC SDP payload that includes active STUN and TURN candidates easily exceeds 1,500 to 2,500 bytes.17 An 881-byte SDP is very small, indicating that it contains almost no candidate descriptors.17  
This size profile confirms that the client browser is failing to gather srflx and relay candidates during the preflight ICE gathering phase.17 This occurs because direct UDP STUN requests are blocked on the client's local network, and the browser cannot connect to Coturn over UDP to gather relay candidates.10  
To bypass this restriction, the system must provide a TCP-based TURN pathway (transport=tcp), allowing the browser to establish a stateful TCP handshake to Coturn over port 62011\.10

### **Root Cause 4: Split-Horizon and Hairpin NAT Routing Constraints**

When testing the application from a client device connected to the same local area network (LAN) as the Synology NAS (but utilizing the public DDNS address peterjfrancoiii2.synology.me), connection failures often occur due to NAT loopback (hairpinning) limitations on consumer-grade routers.9  
If the local router does not support hairpin NAT, any packet sent from a LAN client to the WAN IP address (108.2.161.76) is discarded by the router's firewall rather than being looped back to the NAS local IP (192.168.0.193).1 Under these conditions, direct STUN checks fail, forcing the browser to fall back to a TURN relay or a WSS connection.9

## **Coturn Relay and NAT Traversal Configuration Audit**

To implement a reliable TURN relay framework on Synology, Coturn must be removed from the bridged network namespace and configured to handle NAT traversal directly.3

### **Table 3: Comparative Analysis of Coturn Deployment Methods**

| Configuration Parameter | Bridge Network Namespace (Current) | Host Network Namespace (Proposed) | Technical Implication & Impact on WebRTC |
| :---- | :---- | :---- | :---- |
| **Source IP Preservation** | **Masqueraded** (Source IP rewritten to 172.22.0.1) 6 | **Preserved** (Actual client WAN IP visible to Coturn) 3 | Direct source IP mapping is required for Coturn to authorize and allocate relay sockets.37 |
| **Port Binding Efficiency** | **Poor** (Docker proxy overhead on large port ranges) 42 | **Excellent** (Native kernel socket binding, low latency) 3 | WebRTC requires rapid packet processing; Docker bridge NAT introduces jitter and packet loss on high port ranges.14 |
| **Dynamic IP NAT Mapping** | Statically mapped inside container config 2 | Dynamically mapped using a DSM Task Scheduler automation script 12 | Prevents connection dropouts when the residential ISP rotates the public IP lease.12 |
| **TCP / TLS Listener Support** | Limited by proxy translation rules | Native port binding on host interface 3 | Ensures TCP TURN fallback works when UDP is blocked.10 |

### **Shared Namespace Limitations and the Masquerading Loop**

In the existing architecture, RA2\_Coturn shares the network namespace of Cloud\_Gaming\_Player1 to simplify network routing. However, because both containers are bound to a virtual bridge, Coturn inherits the same masquerading issues as the media helper.6  
When the client browser attempts to connect to Coturn over UDP on port 62011, the incoming packets are proxied through the host.3 The source IP is rewritten to 172.22.0.1, which prevents Coturn from associating the incoming STUN/TURN allocations with the remote client's actual public network socket.6  
To resolve this issue, Coturn must be run in **Host Network Mode**.3 This allows the container to bypass the bridge NAT entirely and bind directly to the Synology host interfaces, exposing the remote client's true public IP.3

## **Immediate Experimental Run**

To verify these findings, the system administrator should execute an isolated, one-connection diagnostic run. This test confirms whether client source IP masquerading is occurring and captures the candidate profiles generated during negotiation.

### **Step 1: Initialize Detailed Kernel and Container Logging**

SSH into MediaServer2 and execute the following command to monitor the container and host socket namespaces in real time:

Bash  
\# Clean up existing containers to prevent stale state issues  
sudo docker stop Cloud\_Gaming\_Player1 RA2\_Coturn 2\>/dev/null  
sudo docker rm Cloud\_Gaming\_Player1 RA2\_Coturn 2\>/dev/null

\# Start the logging trace for the game container and the Coturn server  
sudo /usr/local/bin/docker compose \-f /volume2/Data/App\_Development/ra2-lan-party/project/compose.yaml \\  
  \-f /volume2/Data/App\_Development/ra2-lan-party/project/compose.ultra.yaml \\  
  \-f /volume2/Data/App\_Development/ra2-lan-party/project/compose.ultra-udp.yaml up \-d

\# Execute a tcpdump trace on the Synology host to verify incoming UDP source IPs  
sudo tcpdump \-nni any port 62011 or port range 62001-62010 \-c 50

### **Step 2: Extract and Analyze Client-Side SDP Payload**

To evaluate candidate generation and identify the presence of mDNS or blocked STUN paths, run this diagnostic script in the remote client browser's developer console during a connection attempt 23:

JavaScript  
// Browser Console Diagnostic Script: SDP Candidate Analyzer  
(function() {  
    const pc \= new RTCPeerConnection({  
        iceServers:  
    });

    pc.createOffer({ offerToReceiveVideo: true }).then(async offer \=\> {  
        await pc.setLocalDescription(offer);  
        console.log("%c Local Description Set", "color: green; font-weight: bold;");  
    });

    pc.onicecandidate \= (event) \=\> {  
        if (event.candidate) {  
            const cand \= event.candidate.candidate;  
            const parts \= cand.split(" ");  
            const type \= parts; // Candidate type (host, srflx, relay)  
            const proto \= parts; // Protocol (udp, tcp)  
            const ip \= parts; // Ip address  
            const port \= parts; // Port  
              
            console.log(\`%c\[ICE Candidate Gathered\] Type: ${type} | Proto: ${proto} | Addr: ${ip}:${port}\`, "color: blue;");  
              
            if (ip.endsWith(".local")) {  
                console.warn("\[Privacy Constraint\] mDNS Masking active. Host IP is hidden.");  
            }  
        } else {  
            console.log("%c\[ICE Gathering Complete\]", "color: green; font-weight: bold;");  
            const sdp \= pc.localDescription.sdp;  
            const sdpBytes \= new Blob(\[sdp\]).size;  
            console.log(\`SDP Payload Size: ${sdpBytes} bytes\`);  
              
            const hasSrflx \= sdp.includes("typ srflx");  
            const hasRelay \= sdp.includes("typ relay");  
            console.log(\`SDP Analysis \-\> Has STUN (srflx): ${hasSrflx} | Has TURN (relay): ${hasRelay}\`);  
        }  
    };  
})();

#### **Analyzing the Diagnostic Output:**

* **Scenario A:** If the output displays Has STUN (srflx): false and Has TURN (relay): false while the SDP size is under 900 bytes, the client's local network is blocking outbound UDP STUN traffic, and Coturn is unreachable.17  
* **Scenario B:** If mDNS candidates are displayed without any corresponding public IP addresses, the receive-only page context is preventing direct peer-to-peer connections, making Coturn TCP fallback mapping necessary.9

## **Concrete Code and Configuration Remediation Diff**

To resolve these transport failures, the system must be transitioned to host networking, Coturn configuration parameters corrected, and client-side fallback routes established.2

                               \+-------------------------------------+  
                               |      Physical Synology Host         |  
                               |      Network (192.168.0.193)        |  
                               \+-------------------------------------+  
                                     /                         \\  
                       (Bypasses Bridge NAT)              (Bypasses Bridge NAT)  
                                   /                             \\  
                                  v                               v  
                     \+-------------------------+     \+-------------------------+  
                     |  Cloud\_Gaming\_Player1   |     |       RA2\_Coturn        |  
                     |   \`network\_mode: host\`  |     |   \`network\_mode: host\`  |  
                     \+-------------------------+     \+-------------------------+  
                                  |                               |  
                     Binds directly to physical      Binds directly to physical  
                     UDP Ports 62001-62010           Port 62011 (UDP and TCP)

### **Step 1: Update the Docker Compose Stack**

Modify /volume2/Data/App\_Development/ra2-lan-party/project/compose.ultra-udp.yaml to enforce host networking and remove the virtualized bridge proxy layer 3:

YAML  
\# compose.ultra-udp.yaml (Remediated)  
version: '3.8'

services:  
  Cloud\_Gaming\_Player1:  
    image: ra2-gaming-player:latest  
    container\_name: Cloud\_Gaming\_Player1  
    network\_mode: "host" \# Bypasses Synology's userland proxy NAT   
    environment:  
      \- ULTRA\_VIDEO\_UDP=1  
      \- WEBRTC\_ENABLED=1  
      \- WEBRTC\_ICE\_CANDIDATE\_HOST=peterjfrancoiii2.synology.me  
      \- WEBRTC\_UDP\_PORT\_MIN=62001  
      \- WEBRTC\_UDP\_PORT\_MAX=62010  
      \- WEBRTC\_VIDEO\_UDP\_PORT\_MIN=62001  
      \- WEBRTC\_VIDEO\_UDP\_PORT\_MAX=62010  
      \- WEBRTC\_AUDIO\_ENABLED=0  
      \- WEBRTC\_TURN\_URLS=turn:peterjfrancoiii2.synology.me:62011?transport=udp,turn:peterjfrancoiii2.synology.me:62011?transport=tcp  
      \- WEBRTC\_TURN\_USERNAME=ra2turn  
      \- WEBRTC\_TURN\_PASSWORD=Ra2TurnRelay2026\!  
    volumes:  
      \- /volume2/Data/App\_Development/ra2-lan-party/project:/volume2/Data/App\_Development/ra2-lan-party/project  
    restart: unless-stopped

  RA2\_Coturn:  
    image: coturn/coturn:latest  
    container\_name: RA2\_Coturn  
    network\_mode: "host" \# Bind directly to Synology interface to preserve WAN source IP \[8, 36\]  
    volumes:  
      \- /volume2/Data/App\_Development/ra2-lan-party/project/coturn/turnserver.conf:/etc/coturn/turnserver.conf:ro  
    restart: unless-stopped

Note: Since host network mode is active, the explicit ports publishing block is omitted.3 The containers bind directly to the host ports specified in their respective application configurations.3

### **Step 2: Correct Coturn Server Configuration**

Modify the Coturn configuration file /volume2/Data/App\_Development/ra2-lan-party/project/coturn/turnserver.conf to handle NAT routing and enable TCP/TLS fallback pathways 2:

Ini, TOML  
\# /volume2/Data/App\_Development/ra2-lan-party/project/coturn/turnserver.conf

\# \=== Identity \===  
realm=peterjfrancoiii2.synology.me  
server-name=peterjfrancoiii2.synology.me

\# \=== Networking & Ports \===  
\# Bind directly to all available host physical interfaces  
listening-ip=0.0.0.0  
listening-port=62011

\# Restrict the allocation relay range  
min-port=62012  
max-port=62014

\# Define local interface IP for relaying media out to the private network  
relay-ip=192.168.0.193

\# \=== NAT Mapping (Crucial) \===  
\# Map the external public IP to the local private IP.  
\# This IP is dynamically updated by the DSM Task Scheduler automation script.  
external-ip=108.2.161.76/192.168.0.193

\# \=== Security & Protocols \===  
fingerprint  
lt-cred-mech  
user=ra2turn:Ra2TurnRelay2026\!

\# Disable unused features to reduce overhead and secure the relay  
no-multicast-peers  
no-loopback-peers  
no-tcp-relay \# Disable TCP relaying to the game container; only allow UDP media transport \[41, 45\]

### **Step 3: Implement Dynamic NAT Configuration via DSM Task Scheduler**

Because the Synology NAS resides behind a dynamic public IP address, statically declaring external-ip=108.2.161.76/192.168.0.193 in turnserver.conf will cause connection failures when the ISP rotates the public IP lease.12 Coturn does not automatically refresh this value.12  
To resolve this issue, the system administrator can utilize an automated shell script executed via the **Synology DSM Task Scheduler**.13 This script resolves the DDNS domain, compares it to the currently configured IP in turnserver.conf, and dynamically updates the file and restarts Coturn if a change is detected.12

#### **Automation Script: update\_coturn\_ip.sh**

Create a script file at /volume2/Data/App\_Development/ra2-lan-party/project/coturn/update\_coturn\_ip.sh:

Bash  
\#\!/bin/bash

\# Configuration  
CONFIG\_PATH="/volume2/Data/App\_Development/ra2-lan-party/project/coturn/turnserver.conf"  
CONTAINER\_NAME="RA2\_Coturn"  
DDNS\_DOMAIN="peterjfrancoiii2.synology.me"  
INTERNAL\_IP="192.168.0.193"

\# Resolve the current WAN IP using dynamic DNS  
CURRENT\_WAN\_IP=$(nslookup "$DDNS\_DOMAIN" | awk '/^Address: / { print $2 }' | head \-n1)

if; then  
    echo "$(date): Error \- Failed to resolve DDNS domain $DDNS\_DOMAIN"  
    exit 1  
fi

\# Extract the currently configured external-ip from the config file  
CONFIGURED\_IP\_LINE=$(grep \-E "^external-ip=" "$CONFIG\_PATH")  
EXPECTED\_IP\_LINE="external-ip=$CURRENT\_WAN\_IP/$INTERNAL\_IP"

if; then  
    echo "$(date): WAN IP change detected. Old line: '$CONFIGURED\_IP\_LINE', New line: '$EXPECTED\_IP\_LINE'"  
      
    \# Backup config file  
    cp "$CONFIG\_PATH" "${CONFIG\_PATH}.bak"  
      
    \# Replace the configuration line  
    if grep \-q "^external-ip=" "$CONFIG\_PATH"; then  
        sed \-i "s|^external-ip=.\*|$EXPECTED\_IP\_LINE|" "$CONFIG\_PATH"  
    else  
        echo "$EXPECTED\_IP\_LINE" \>\> "$CONFIG\_PATH"  
    fi  
      
    \# Restart the Coturn container to apply configuration changes  
    echo "$(date): Restarting Docker container $CONTAINER\_NAME..."  
    docker restart "$CONTAINER\_NAME"  
else  
    echo "$(date): WAN IP is unchanged ($CURRENT\_WAN\_IP). No action required."  
fi

#### **Mounting the Script in Synology Task Scheduler:**

1. Navigate to **DSM Control Panel \> Task Scheduler**.  
2. Click **Create \> Triggered Task \> User-defined script**.  
3. Set **Task** name to Update Coturn IP.  
4. Set **User** to root.  
5. Under **Task Settings \> Run command**, enter:  
   bash /volume2/Data/App\_Development/ra2-lan-party/project/coturn/update\_coturn\_ip.sh \>\> /volume2/Data/App\_Development/ra2-lan-party/project/coturn/ip\_update.log 2\>&1  
6. Click **Create \> Scheduled Task \> User-defined script** to run this task every 30 minutes, ensuring minimal downtime during WAN rotations.13

### **Step 4: Correct Client-Side WebRTC Initialization in ultra-play.js**

To ensure the remote browser client can fall back to TCP TURN when UDP is blocked on the local network, update the configuration block in container/remote-ultra/ultra-play.js 10:

JavaScript  
// container/remote-ultra/ultra-play.js (Remediated)

const iceServers \=,  
        username: "ra2turn",  
        credential: "Ra2TurnRelay2026\!"  
    }  
\];

// Configure the peer connection  
const rtcConfig \= {  
    iceServers: iceServers,  
    iceTransportPolicy: "all", // Allow both direct STUN (srflx) and relayed (relay) connections  
    iceCandidatePoolSize: 2     // Pre-gather candidates to accelerate connection establishment  
};

const pc \= new RTCPeerConnection(rtcConfig);

## **Fallback and Long-Term Recommendations**

If the proposed configuration changes do not establish a stable WebRTC/UDP connection on the client network, the system administrator should evaluate the following structural options 34:

### **Option 1: Retain the WebCodecs/WSS Fallback Pathway**

If the client's firewall completely blocks high UDP/TCP ports (restricting outbound traffic strictly to port 80 and 443), WebRTC transport is impossible without running a TURN-over-TLS (TURNS) relay on port 443\.39  
In this scenario, retaining the current WebCodecs H265/WSS fallback is the most practical solution.1 The WSS pathway operates over the standard HTTPS port (6081), allowing it to pass through strict corporate firewalls and reverse proxies without additional port-forwarding requirements.1

### **Option 2: Deploy Coturn on a Standard HTTPS Port (Port 443\)**

If low latency is required but the client network blocks port 62011, Coturn can be reconfigured to listen directly on port 443\.39 Because port 443 is almost always open on corporate and public networks, this ensures that the browser can establish a secure TLS-encrypted TURN (turns:) connection.39  
However, because port 443 on the Synology NAS is typically reserved for standard HTTPS web traffic, this configuration requires a dedicated IP address for Coturn or a stream-based reverse proxy configuration utilizing SNI routing.37

### **Option 3: Implement Hosted TURN Solutions**

For deployments where maintaining a self-hosted Coturn instance is impractical due to dynamic IP constraints or symmetric NAT routing limitations, migrating to a managed TURN provider (e.g., Turnix.io) is recommended.36 Managed providers offer globally distributed, highly available relay networks on port 443 and handles credential generation and dynamic routing automatically, ensuring reliable fallback pathways with minimal latency.36

#### **Works cited**

1. Exposing a container externally \- Synology Community, accessed June 14, 2026, [https://community.synology.com/enu/forum/1/post/192333](https://community.synology.com/enu/forum/1/post/192333)  
2. Start a TURN Server, accessed June 14, 2026, [https://abcamus.github.io/sync-vault-doc/cloud-service/turn-server](https://abcamus.github.io/sync-vault-doc/cloud-service/turn-server)  
3. Connect to a docker container from outside the host (same network) \- Synology Community, accessed June 14, 2026, [https://community.synology.com/enu/forum/17/post/102280](https://community.synology.com/enu/forum/17/post/102280)  
4. Configuring Audio/Video with a TURN Server | CodeTogether Documentation, accessed June 14, 2026, [https://docs.codetogether.com/install/backend/turn-server](https://docs.codetogether.com/install/backend/turn-server)  
5. Get external IP in docker container with bridged networking \- Synology Community, accessed June 14, 2026, [https://community.synology.com/enu/forum/1/post/154181](https://community.synology.com/enu/forum/1/post/154181)  
6. How to retain source IP from WAN when in bridge mode (Plex container) : r/docker \- Reddit, accessed June 14, 2026, [https://www.reddit.com/r/docker/comments/uv2vl7/how\_to\_retain\_source\_ip\_from\_wan\_when\_in\_bridge/](https://www.reddit.com/r/docker/comments/uv2vl7/how_to_retain_source_ip_from_wan_when_in_bridge/)  
7. Running webrtc in a docker container: candidate IP issue \- GStreamer Discourse, accessed June 14, 2026, [https://discourse.gstreamer.org/t/running-webrtc-in-a-docker-container-candidate-ip-issue/450](https://discourse.gstreamer.org/t/running-webrtc-in-a-docker-container-candidate-ip-issue/450)  
8. PSA: Private IP addresses exposed by WebRTC changing to mDNS ..., accessed June 14, 2026, [https://groups.google.com/g/discuss-webrtc/c/6stQXi72BEU](https://groups.google.com/g/discuss-webrtc/c/6stQXi72BEU)  
9. Force TCP for WebRTC PeerConnections \- Stack Overflow, accessed June 14, 2026, [https://stackoverflow.com/questions/35062682/force-tcp-for-webrtc-peerconnections](https://stackoverflow.com/questions/35062682/force-tcp-for-webrtc-peerconnections)  
10. Using WebRTC ICE Servers for Port Scanning in Chrome | by Jacob Baines \- Medium, accessed June 14, 2026, [https://medium.com/tenable-techblog/using-webrtc-ice-servers-for-port-scanning-in-chrome-ce17b19dd474](https://medium.com/tenable-techblog/using-webrtc-ice-servers-for-port-scanning-in-chrome-ce17b19dd474)  
11. coturn external-ip from DNS? · Issue \#563 · coturn/coturn \- GitHub, accessed June 14, 2026, [https://github.com/coturn/coturn/issues/563](https://github.com/coturn/coturn/issues/563)  
12. Building/configuring a TURN server \- Page 3 \- Development \- FreedomBox Forum, accessed June 14, 2026, [https://discuss.freedombox.org/t/building-configuring-a-turn-server/832?page=3](https://discuss.freedombox.org/t/building-configuring-a-turn-server/832?page=3)  
13. Best way to host a TURN server with Coturn \- Google Groups, accessed June 14, 2026, [https://groups.google.com/g/turn-server-project-rfc5766-turn-server/c/XYWWs7iAXJQ](https://groups.google.com/g/turn-server-project-rfc5766-turn-server/c/XYWWs7iAXJQ)  
14. Confusion regarding DDNS and reaching my server from outside the local network \- Reddit, accessed June 14, 2026, [https://www.reddit.com/r/selfhosted/comments/1nwh80l/confusion\_regarding\_ddns\_and\_reaching\_my\_server/](https://www.reddit.com/r/selfhosted/comments/1nwh80l/confusion_regarding_ddns_and_reaching_my_server/)  
15. RTCPeerConnection: iceConnectionState property \- Web APIs | MDN, accessed June 14, 2026, [https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/iceConnectionState](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/iceConnectionState)  
16. WebRTC PeerConnection failing with ice candidates in offer/answer \- Stack Overflow, accessed June 14, 2026, [https://stackoverflow.com/questions/75942829/webrtc-peerconnection-failing-with-ice-candidates-in-offer-answer](https://stackoverflow.com/questions/75942829/webrtc-peerconnection-failing-with-ice-candidates-in-offer-answer)  
17. WebRTC onTrack not triggered \- Stack Overflow, accessed June 14, 2026, [https://stackoverflow.com/questions/78444082/webrtc-ontrack-not-triggered](https://stackoverflow.com/questions/78444082/webrtc-ontrack-not-triggered)  
18. Services that need to know source IP; host networking only? \- Docker Community Forums, accessed June 14, 2026, [https://forums.docker.com/t/services-that-need-to-know-source-ip-host-networking-only/141884](https://forums.docker.com/t/services-that-need-to-know-source-ip-host-networking-only/141884)  
19. Use specific ports for webRTC \- Stack Overflow, accessed June 14, 2026, [https://stackoverflow.com/questions/29563830/use-specific-ports-for-webrtc](https://stackoverflow.com/questions/29563830/use-specific-ports-for-webrtc)  
20. WebRTCbin / ICE Connection issues \- General Discussion \- GStreamer Discourse, accessed June 14, 2026, [https://discourse.gstreamer.org/t/webrtcbin-ice-connection-issues/1470](https://discourse.gstreamer.org/t/webrtcbin-ice-connection-issues/1470)  
21. libnice – The GLib ICE implementation, accessed June 14, 2026, [https://libnice.freedesktop.org/](https://libnice.freedesktop.org/)  
22. ICE candidates and active connections in WebRTC \- BlogGeek.me, accessed June 14, 2026, [https://bloggeek.me/webrtc-ice-connection/](https://bloggeek.me/webrtc-ice-connection/)  
23. Docker containers are unable to reach public internet on bridge mode, accessed June 14, 2026, [https://community.synology.com/enu/forum/11/post/142221](https://community.synology.com/enu/forum/11/post/142221)  
24. Routing from docker containers using a different physical network interface and default gateway \- Server Fault, accessed June 14, 2026, [https://serverfault.com/questions/696747/routing-from-docker-containers-using-a-different-physical-network-interface-and](https://serverfault.com/questions/696747/routing-from-docker-containers-using-a-different-physical-network-interface-and)  
25. WebRTC Issues and How to Debug Them \- CloudBees, accessed June 14, 2026, [https://www.cloudbees.com/blog/webrtc-issues-and-how-to-debug-them](https://www.cloudbees.com/blog/webrtc-issues-and-how-to-debug-them)  
26. WebRTC Leak Shield: Complete Guide to Blocking Browser IP Leaks \- Undetectable.io, accessed June 14, 2026, [https://undetectable.io/blog/web-rtc-leaks-shield/](https://undetectable.io/blog/web-rtc-leaks-shield/)  
27. PSA: Private IP addresses exposed by WebRTC changing to mDNS hostnames, accessed June 14, 2026, [https://groups.google.com/g/discuss-webrtc/c/6stQXi72BEU/m/2FwZd24UAQAJ](https://groups.google.com/g/discuss-webrtc/c/6stQXi72BEU/m/2FwZd24UAQAJ)  
28. Using GStreamer webrtcbin as MediaSoup client \- Integration, accessed June 14, 2026, [https://mediasoup.discourse.group/t/using-gstreamer-webrtcbin-as-mediasoup-client/590](https://mediasoup.discourse.group/t/using-gstreamer-webrtcbin-as-mediasoup-client/590)  
29. webrtc-unidirectional-h264 no video on browser · Issue \#222 · centricular/gstwebrtc-demos, accessed June 14, 2026, [https://github.com/centricular/gstwebrtc-demos/issues/222](https://github.com/centricular/gstwebrtc-demos/issues/222)  
30. WebRTC support in WebKitGTK and WPEWebKit with GStreamer: Current status and plans \- FOSDEM 2026, accessed June 14, 2026, [https://fosdem.org/2026/events/attachments/KMMLGM-webrtc\_support\_in\_webkitgtk\_and\_wpewebkit\_with\_gstreamer\_current\_status\_and\_plan/slides/266710/webrtc\_su\_twrfhlu.pdf](https://fosdem.org/2026/events/attachments/KMMLGM-webrtc_support_in_webkitgtk_and_wpewebkit_with_gstreamer_current_status_and_plan/slides/266710/webrtc_su_twrfhlu.pdf)  
31. 6.13.2 (May 2020\) — Kurento 7.3-dev documentation, accessed June 14, 2026, [https://doc-kurento.readthedocs.io/en/latest/project/relnotes/v6\_13\_2.html](https://doc-kurento.readthedocs.io/en/latest/project/relnotes/v6_13_2.html)  
32. 6.13.0 (December 2019\) — Kurento 7.3 documentation \- Read the Docs, accessed June 14, 2026, [https://doc-kurento.readthedocs.io/en/stable/project/relnotes/v6\_13\_0.html](https://doc-kurento.readthedocs.io/en/stable/project/relnotes/v6_13_0.html)  
33. No WebRTC connection \- Milestone Documentation, accessed June 14, 2026, [https://doc.milestonesys.com/en-US/bundle/doc1042\_ver1/page/content/standard\_features/apigateway/troubleshooting/api\_gway\_no-webrtc-connection.htm](https://doc.milestonesys.com/en-US/bundle/doc1042_ver1/page/content/standard_features/apigateway/troubleshooting/api_gway_no-webrtc-connection.htm)  
34. Dockerized server application as a WebRTC peer : r/networking \- Reddit, accessed June 14, 2026, [https://www.reddit.com/r/networking/comments/19dh43y/dockerized\_server\_application\_as\_a\_webrtc\_peer/](https://www.reddit.com/r/networking/comments/19dh43y/dockerized_server_application_as_a_webrtc_peer/)  
35. Coturn \+ Docker: A Practical, Detailed Guide | Turnix.io Guides, accessed June 14, 2026, [https://turnix.io/guides/setup-coturn-server](https://turnix.io/guides/setup-coturn-server)  
36. Make coturn work reverse proxied through nginx · Issue \#702 \- GitHub, accessed June 14, 2026, [https://github.com/coturn/coturn/issues/702](https://github.com/coturn/coturn/issues/702)  
37. How to redirect my IP to domain name \-Coturn \- Server Fault, accessed June 14, 2026, [https://serverfault.com/questions/1158335/how-to-redirect-my-ip-to-domain-name-coturn](https://serverfault.com/questions/1158335/how-to-redirect-my-ip-to-domain-name-coturn)  
38. Turn Server Configuration \- BigBlueButton, accessed June 14, 2026, [https://docs.bigbluebutton.org/administration/turn-server/](https://docs.bigbluebutton.org/administration/turn-server/)  
39. Chrome sends UDP STUN requests although the TURN server is configured as TCP \[42229160\] \- WebRTC, accessed June 14, 2026, [https://issues.webrtc.org/42229160](https://issues.webrtc.org/42229160)  
40. Securing coturn: Configuration Guide, accessed June 14, 2026, [https://www.enablesecurity.com/blog/coturn-security-configuration-guide/](https://www.enablesecurity.com/blog/coturn-security-configuration-guide/)  
41. coturn/docker/coturn/README.md at master \- GitHub, accessed June 14, 2026, [https://github.com/coturn/coturn/blob/master/docker/coturn/README.md](https://github.com/coturn/coturn/blob/master/docker/coturn/README.md)  
42. Dynamic external IP and coturn · Issue \#413 · spantaleev/matrix-docker-ansible-deploy, accessed June 14, 2026, [https://github.com/spantaleev/matrix-docker-ansible-deploy/issues/413](https://github.com/spantaleev/matrix-docker-ansible-deploy/issues/413)  
43. WebRTC on Chrome; how do I know if it's using UDP or TCP \- Stack Overflow, accessed June 14, 2026, [https://stackoverflow.com/questions/31419789/webrtc-on-chrome-how-do-i-know-if-its-using-udp-or-tcp](https://stackoverflow.com/questions/31419789/webrtc-on-chrome-how-do-i-know-if-its-using-udp-or-tcp)  
44. Run coturn server with dynamic IP, accessed June 14, 2026, [https://www.guiard.org/pages/other/coturn-dynamic-ip.html](https://www.guiard.org/pages/other/coturn-dynamic-ip.html)  
45. WebRTC TURN Servers: When you NEED it \- BlogGeek.me, accessed June 14, 2026, [https://bloggeek.me/webrtc-turn/](https://bloggeek.me/webrtc-turn/)  
46. TURN over TCP/443 \- Google Groups, accessed June 14, 2026, [https://groups.google.com/g/turn-server-project-rfc5766-turn-server/c/ee9cUtgKFEI](https://groups.google.com/g/turn-server-project-rfc5766-turn-server/c/ee9cUtgKFEI)  
47. Requests with incorrect source IP from another network \- Docker Community Forums, accessed June 14, 2026, [https://forums.docker.com/t/requests-with-incorrect-source-ip-from-another-network/139198](https://forums.docker.com/t/requests-with-incorrect-source-ip-from-another-network/139198)  
48. ICE Candidate Gathering Never Completes in Production : r/WebRTC \- Reddit, accessed June 14, 2026, [https://www.reddit.com/r/WebRTC/comments/1dn1p90/ice\_candidate\_gathering\_never\_completes\_in/](https://www.reddit.com/r/WebRTC/comments/1dn1p90/ice_candidate_gathering_never_completes_in/)