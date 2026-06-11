FROM archlinux:latest

ARG NOVNC_REF=v1.5.0
ARG WEBSOCKIFY_REF=v0.12.0
ARG WINE_BUILD=10.8
ARG WINE_VARIANT=amd64-wow64

COPY container/patch-novnc.sh /opt/ra2/patch-novnc.sh
COPY container/latency-overlay.js /opt/ra2/latency-overlay.js
COPY container/cursor-lock.js /opt/ra2/cursor-lock.js
COPY container/remote/ /opt/ra2/remote/

RUN printf '\nDisableSandbox\nNoExtract = usr/share/doc/* usr/share/help/* usr/share/locale/* usr/share/man/* usr/share/licenses/*\n' >> /etc/pacman.conf \
    && pacman -Syu --noconfirm \
    && pacman -S --needed --noconfirm \
      alsa-lib \
      alsa-plugins \
      alsa-utils \
      ca-certificates \
      curl \
      ffmpeg \
      gcc \
      git \
      gstreamer \
      gst-libav \
      gst-plugin-va \
      gst-plugins-bad \
      gst-plugins-base \
      gst-plugins-good \
      gst-plugins-ugly \
      libglvnd \
      libmfx \
      libva \
      libva-intel-driver \
      libva-utils \
      mesa \
      openbox \
      pulseaudio \
      pulseaudio-alsa \
      python \
      python-gobject \
      python-websockets \
      python-numpy \
      pkgconf \
      socat \
      xdotool \
      supervisor \
      tar \
      vpl-gpu-rt \
      x11vnc \
      xorg-server-xvfb \
      xz \
    && curl -fsSL -o /tmp/wine.tar.xz "https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_BUILD}/wine-${WINE_BUILD}-${WINE_VARIANT}.tar.xz" \
    && mkdir -p /opt/wine \
    && tar -xJf /tmp/wine.tar.xz -C /opt/wine --strip-components=1 \
    && rm /tmp/wine.tar.xz \
    && git clone --depth 1 --branch "${NOVNC_REF}" https://github.com/novnc/noVNC.git /opt/novnc \
    && git clone --depth 1 --branch "${WEBSOCKIFY_REF}" https://github.com/novnc/websockify.git /opt/novnc/utils/websockify \
    && ln -sf /opt/novnc/vnc.html /opt/novnc/index.html \
    && chmod +x /opt/novnc/utils/websockify/run \
    && chmod +x /opt/ra2/patch-novnc.sh \
    && /opt/ra2/patch-novnc.sh /opt/novnc \
    && ln -sf /opt/ra2/remote/remote.html /opt/novnc/remote.html \
    && ln -sf /opt/ra2/remote/remote-play.js /opt/novnc/remote-play.js \
    && rm -f /usr/lib/dri/iHD_drv_video.so \
    && pacman -Rns --noconfirm git \
    && pacman -Scc --noconfirm \
    && useradd -m -u 1000 -s /bin/bash commander \
    && mkdir -p /opt/ra2 /home/commander/game_assets /home/commander/.wine \
    && chown -R commander:commander /opt/ra2 /opt/novnc /opt/wine /home/commander

COPY container/asound.conf /etc/asound.conf
COPY container/pulse/ /opt/ra2/pulse/
COPY container/websockify-tokens.cfg /opt/ra2/websockify-tokens.cfg
COPY --chown=commander:commander container/audio-proxy.sh /opt/ra2/audio-proxy.sh
COPY --chown=commander:commander container/latency-proxy.sh /opt/ra2/latency-proxy.sh
COPY --chown=commander:commander container/latency-overlay.js /opt/ra2/latency-overlay.js
COPY --chown=commander:commander container/cursor-lock.js /opt/ra2/cursor-lock.js
COPY --chown=commander:commander container/start-pulseaudio.sh /opt/ra2/start-pulseaudio.sh
COPY --chown=commander:commander container/start-websockify.sh /opt/ra2/start-websockify.sh
COPY --chown=commander:commander container/start-x11vnc.sh /opt/ra2/start-x11vnc.sh
COPY --chown=commander:commander container/healthcheck-novnc.sh /opt/ra2/healthcheck-novnc.sh
COPY --chown=commander:commander container/webrtc-media.py /opt/ra2/webrtc-media.py
COPY --chown=commander:commander container/webrtc-media-helper.c /opt/ra2/webrtc-media-helper.c
COPY --chown=commander:commander container/input-proxy.py /opt/ra2/input-proxy.py
COPY --chown=commander:commander container/uinput_backend.py /opt/ra2/uinput_backend.py
COPY --chown=commander:commander container/start-webrtc.sh /opt/ra2/start-webrtc.sh
COPY --chown=commander:commander container/start-input-proxy.sh /opt/ra2/start-input-proxy.sh
COPY --chown=commander:commander container/remote/ /opt/ra2/remote/
COPY --chown=commander:commander container/entrypoint.sh /opt/ra2/entrypoint.sh
COPY --chown=commander:commander container/supervisord.conf /opt/ra2/supervisord.conf

RUN gcc /opt/ra2/webrtc-media-helper.c -o /opt/ra2/webrtc-media-helper \
      $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-webrtc-1.0 gstreamer-sdp-1.0) \
    && chmod +x /opt/ra2/entrypoint.sh /opt/ra2/audio-proxy.sh /opt/ra2/latency-proxy.sh \
      /opt/ra2/start-pulseaudio.sh /opt/ra2/start-websockify.sh /opt/ra2/start-x11vnc.sh \
      /opt/ra2/healthcheck-novnc.sh \
      /opt/ra2/patch-novnc.sh /opt/ra2/start-webrtc.sh /opt/ra2/start-input-proxy.sh \
      /opt/ra2/webrtc-media.py /opt/ra2/input-proxy.py /opt/ra2/webrtc-media-helper \
    && chown commander:commander /opt/ra2/webrtc-media-helper

USER commander
WORKDIR /home/commander

ENV PATH="/opt/wine/bin:${PATH}" \
    DISPLAY=:1 \
    WINEARCH=win64 \
    WINEPREFIX=/home/commander/.wine \
    WINEDEBUG=-all \
    LIBVA_DRIVER_NAME=i965 \
    GST_VAAPI_ALL_DRIVERS=1 \
    GST_VA_ALL_DRIVERS=1 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    MESA_GL_VERSION_OVERRIDE=2.1

EXPOSE 6080

ENTRYPOINT ["/opt/ra2/entrypoint.sh"]
