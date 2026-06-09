FROM archlinux:latest

ARG NOVNC_REF=v1.5.0
ARG WEBSOCKIFY_REF=v0.12.0
ARG WINE_BUILD=10.8
ARG WINE_VARIANT=amd64-wow64

RUN printf '\nDisableSandbox\nNoExtract = usr/share/doc/* usr/share/help/* usr/share/locale/* usr/share/man/* usr/share/licenses/*\n' >> /etc/pacman.conf \
    && pacman -Syu --noconfirm \
    && pacman -S --needed --noconfirm \
      alsa-lib \
      alsa-utils \
      ca-certificates \
      curl \
      ffmpeg \
      git \
      gstreamer \
      gst-libav \
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
      python \
      python-numpy \
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
    && rm -f /usr/lib/dri/iHD_drv_video.so \
    && pacman -Rns --noconfirm git \
    && pacman -Scc --noconfirm \
    && useradd -m -u 1000 -s /bin/bash commander \
    && mkdir -p /opt/ra2 /home/commander/game_assets /home/commander/.wine \
    && chown -R commander:commander /opt/ra2 /opt/novnc /opt/wine /home/commander

COPY container/asound.conf /etc/asound.conf
COPY --chown=commander:commander container/entrypoint.sh /opt/ra2/entrypoint.sh
COPY --chown=commander:commander container/supervisord.conf /opt/ra2/supervisord.conf

RUN chmod +x /opt/ra2/entrypoint.sh

USER commander
WORKDIR /home/commander

ENV PATH="/opt/wine/bin:${PATH}" \
    DISPLAY=:1 \
    WINEARCH=win64 \
    WINEPREFIX=/home/commander/.wine \
    WINEDEBUG=-all \
    LIBVA_DRIVER_NAME=i965 \
    GST_VAAPI_ALL_DRIVERS=1 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    MESA_GL_VERSION_OVERRIDE=2.1

EXPOSE 6080

ENTRYPOINT ["/opt/ra2/entrypoint.sh"]
