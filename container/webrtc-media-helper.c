#define GST_USE_UNSTABLE_API
#include <gst/gst.h>
#include <gst/sdp/sdp.h>
#include <gst/webrtc/webrtc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static GMainLoop *main_loop;
static GstElement *pipeline;
static GstElement *webrtc;
static gboolean offer_requested = FALSE;

static const gchar *env_str(const gchar *name, const gchar *fallback) {
  const gchar *value = g_getenv(name);
  return (value && *value) ? value : fallback;
}

static gint env_int(const gchar *name, gint fallback) {
  const gchar *value = g_getenv(name);
  return (value && *value) ? atoi(value) : fallback;
}

static gboolean factory_exists(const gchar *name) {
  GstElementFactory *factory = gst_element_factory_find(name);
  if (!factory) {
    return FALSE;
  }
  gst_object_unref(factory);
  return TRUE;
}

static gboolean codec_is_h264(const gchar *codec) {
  return g_ascii_strcasecmp(codec, "H264") == 0 || g_ascii_strcasecmp(codec, "AVC") == 0;
}

static gboolean codec_is_h265(const gchar *codec) {
  return g_ascii_strcasecmp(codec, "H265") == 0 || g_ascii_strcasecmp(codec, "HEVC") == 0;
}

static gboolean codec_is_vp8(const gchar *codec) {
  return g_ascii_strcasecmp(codec, "VP8") == 0;
}

static gchar *video_encoder_desc(const gchar **encoding_name) {
  const gchar *codec = env_str("WEBRTC_VIDEO_CODEC", "H264");
  gint bitrate = MAX(env_int("WEBRTC_VIDEO_BITRATE", 1200000) / 1000, 1);
  gint fps = MAX(env_int("WEBRTC_VIDEO_FPS", 30), 1);
  gint key_seconds = MAX(env_int("WEBRTC_VIDEO_KEYFRAME_SECONDS", 1), 1);
  gint key_distance = fps * key_seconds;
  gint rtp_mtu = MAX(env_int("WEBRTC_VIDEO_RTP_MTU", 1000), 500);
  gboolean require_hw = g_strcmp0(env_str("WEBRTC_VIDEO_REQUIRE_HW", "0"), "0") != 0;

  if (codec_is_h264(codec)) {
    if (!require_hw && factory_exists("x264enc")) {
      g_printerr("[webrtc-helper] using software H.264 encoder x264enc\n");
      *encoding_name = "H264";
      return g_strdup_printf(
          "video/x-raw,format=I420 ! "
          "x264enc tune=zerolatency bitrate=%d key-int-max=%d speed-preset=ultrafast ! "
          "video/x-h264,profile=constrained-baseline ! "
          "h264parse config-interval=-1 ! "
          "rtph264pay pt=96 mtu=%d config-interval=-1 aggregate-mode=zero-latency",
          bitrate, key_distance, rtp_mtu);
    }
    if (factory_exists("vah264enc")) {
      g_printerr("[webrtc-helper] using hardware H.264 encoder vah264enc\n");
      *encoding_name = "H264";
      return g_strdup_printf(
          "video/x-raw,format=NV12 ! "
          "vah264enc bitrate=%d key-int-max=%d b-frames=0 ref-frames=1 cabac=false "
          "dct8x8=false target-usage=7 ! "
          "video/x-h264,profile=constrained-baseline,stream-format=byte-stream,alignment=au ! "
          "h264parse config-interval=-1 ! rtph264pay pt=96 mtu=%d config-interval=-1 "
          "aggregate-mode=zero-latency",
          bitrate, key_distance, rtp_mtu);
    }
    if (factory_exists("vaapih264enc")) {
      g_printerr("[webrtc-helper] using hardware H.264 encoder vaapih264enc\n");
      *encoding_name = "H264";
      return g_strdup_printf(
          "video/x-raw,format=NV12 ! "
          "vaapih264enc bitrate=%d key-int-max=%d ! "
          "video/x-h264,profile=constrained-baseline ! "
          "h264parse config-interval=-1 ! rtph264pay pt=96 mtu=%d config-interval=-1 "
          "aggregate-mode=zero-latency",
          bitrate, key_distance, rtp_mtu);
    }
    g_printerr("[webrtc-helper] no H.264 encoder found\n");
    return NULL;
  }

  /* H265/HEVC encodes on DS225+ VA-API but Safari did not render video in this
   * WebRTC path during testing. Keep H264 as WEBRTC_LATENCY_PRESET=stable default. */
  if (codec_is_h265(codec)) {
    if (factory_exists("vah265enc")) {
      g_printerr("[webrtc-helper] using hardware HEVC encoder vah265enc\n");
      *encoding_name = "H265";
      return g_strdup_printf(
          "video/x-raw,format=NV12 ! "
          "vah265enc bitrate=%d key-int-max=%d b-frames=0 ref-frames=1 target-usage=7 ! "
          "video/x-h265,stream-format=byte-stream,alignment=au ! "
          "h265parse config-interval=-1 ! rtph265pay pt=96 mtu=%d config-interval=-1 "
          "aggregate-mode=zero-latency",
          bitrate, key_distance, rtp_mtu);
    }
    if (factory_exists("vaapih265enc")) {
      g_printerr("[webrtc-helper] using hardware HEVC encoder vaapih265enc\n");
      *encoding_name = "H265";
      return g_strdup_printf(
          "video/x-raw,format=NV12 ! "
          "vaapih265enc bitrate=%d keyframe-period=%d ! "
          "video/x-h265,stream-format=byte-stream,alignment=au ! "
          "h265parse config-interval=-1 ! rtph265pay pt=96 mtu=%d config-interval=-1 "
          "aggregate-mode=zero-latency",
          bitrate, key_distance, rtp_mtu);
    }
    if (!require_hw && factory_exists("x265enc")) {
      g_printerr("[webrtc-helper] WARNING: falling back to software x265enc\n");
      *encoding_name = "H265";
      return g_strdup_printf(
          "video/x-raw,format=I420 ! "
          "x265enc tune=zerolatency bitrate=%d key-int-max=%d speed-preset=ultrafast ! "
          "video/x-h265,stream-format=byte-stream,alignment=au ! "
          "h265parse config-interval=-1 ! rtph265pay pt=96 mtu=%d config-interval=-1 "
          "aggregate-mode=zero-latency",
          bitrate, key_distance, rtp_mtu);
    }
    g_printerr("[webrtc-helper] no HEVC encoder found\n");
    return NULL;
  }

  if (codec_is_vp8(codec)) {
    if (require_hw) {
      g_printerr("[webrtc-helper] VP8 software encoder disabled by WEBRTC_VIDEO_REQUIRE_HW=1\n");
      return NULL;
    }
    if (factory_exists("vp8enc")) {
      g_printerr("[webrtc-helper] using software VP8 encoder vp8enc\n");
      *encoding_name = "VP8";
      return g_strdup_printf(
          "video/x-raw,format=I420 ! "
          "vp8enc deadline=1 cpu-used=8 target-bitrate=%d keyframe-max-dist=%d ! "
          "rtpvp8pay pt=96 mtu=%d",
          env_int("WEBRTC_VIDEO_BITRATE", 1200000), key_distance, rtp_mtu);
    }
    g_printerr("[webrtc-helper] no VP8 encoder found\n");
    return NULL;
  }

  g_printerr("[webrtc-helper] unsupported WEBRTC_VIDEO_CODEC=%s\n", codec);
  return NULL;
}

static gchar *pipeline_desc(void) {
  const gchar *encoding_name = "H264";
  gchar *encoder = video_encoder_desc(&encoding_name);
  if (!encoder) {
    return NULL;
  }

  const gchar *display = env_str("DISPLAY", ":1");
  const gchar *stun = env_str("STUN_URL", "stun:stun.l.google.com:19302");
  gint width = env_int("WEBRTC_VIDEO_WIDTH", 1280);
  gint height = env_int("WEBRTC_VIDEO_HEIGHT", 720);
  gint fps = env_int("WEBRTC_VIDEO_FPS", 30);
  gint audio_rate = env_int("WEBRTC_AUDIO_RATE", 44100);
  gint audio_bitrate = env_int("WEBRTC_AUDIO_BITRATE", 96000);
  gint audio_frame_ms = env_int("WEBRTC_AUDIO_FRAME_MS", 10);
  gint pulse_port = env_int("PULSE_TCP_PORT", 4711);
  const gchar *queue =
      "queue max-size-buffers=1 max-size-bytes=0 max-size-time=0 leaky=downstream";

  gchar *desc = g_strdup_printf(
      "webrtcbin name=sendrecv bundle-policy=max-bundle latency=0 stun-server=%s "
      "ximagesrc use-damage=false show-pointer=true do-timestamp=true display-name=%s ! "
      "videorate max-rate=%d ! videoscale method=nearest-neighbour ! "
      "video/x-raw,width=%d,height=%d,framerate=%d/1 ! videoconvert ! %s ! "
      "%s ! %s ! application/x-rtp,media=video,encoding-name=%s,payload=96 ! sendrecv. "
      "tcpclientsrc host=127.0.0.1 port=%d do-timestamp=true ! "
      "rawaudioparse use-sink-caps=false format=pcm pcm-format=s16le sample-rate=%d num-channels=2 ! "
      "audioconvert ! audioresample quality=0 ! %s ! "
      "opusenc bitrate=%d bitrate-type=0 complexity=0 frame-size=%d "
      "audio-type=restricted-lowdelay inband-fec=false dtx=false ! rtpopuspay pt=97 ! "
      "%s ! application/x-rtp,media=audio,encoding-name=OPUS,payload=97 ! sendrecv.",
      stun, display, fps, width, height, fps, queue, encoder, queue, encoding_name, pulse_port,
      audio_rate, queue, audio_bitrate, audio_frame_ms, queue);

  g_free(encoder);
  return desc;
}

static void protocol_line_2(const gchar *type, guint index, const gchar *payload) {
  gchar *encoded = g_base64_encode((const guchar *)payload, strlen(payload));
  g_print("%s %u %s\n", type, index, encoded);
  fflush(stdout);
  g_free(encoded);
}

static void protocol_line_1(const gchar *type, const gchar *payload) {
  gchar *encoded = g_base64_encode((const guchar *)payload, strlen(payload));
  g_print("%s %s\n", type, encoded);
  fflush(stdout);
  g_free(encoded);
}

static gchar *normalize_offer_sdp_for_browsers(const gchar *sdp) {
  GString *normalized = g_string_new(NULL);
  gchar **lines = g_strsplit(sdp, "\n", -1);
  gboolean h264_rtpmap_seen = FALSE;
  gboolean h264_fmtp_seen = FALSE;
  gboolean h265_rtpmap_seen = FALSE;
  gboolean h265_fmtp_seen = FALSE;

  for (gchar **line = lines; line && *line; line++) {
    gchar *clean = g_strchomp(g_strdup(*line));
    if (!*clean) {
      g_free(clean);
      continue;
    }

    if (g_str_has_prefix(clean, "a=fmtp:96 ")) {
      if (g_strstr_len(clean, -1, "profile-level-id") != NULL) {
        h264_fmtp_seen = TRUE;
      } else if (g_strstr_len(clean, -1, "profile-id") != NULL ||
                 g_strstr_len(clean, -1, "sprop-vps") != NULL) {
        h265_fmtp_seen = TRUE;
      }
    }

    if (g_strcmp0(clean, "a=rtcp-mux-only") == 0 ||
        g_strcmp0(clean, "a=bundle-only") == 0) {
      g_free(clean);
      continue;
    }

    if (g_str_has_prefix(clean, "m=audio 0 UDP/TLS/RTP/SAVPF ")) {
      gchar *rewritten = g_strdup(clean);
      rewritten[8] = '9';
      g_string_append_printf(normalized, "%s\r\n", rewritten);
      g_free(rewritten);
      g_free(clean);
      continue;
    }

    g_string_append_printf(normalized, "%s\r\n", clean);

    if (g_strcmp0(clean, "a=rtpmap:96 H264/90000") == 0) {
      h264_rtpmap_seen = TRUE;
      if (!h264_fmtp_seen) {
        g_string_append(normalized,
                        "a=fmtp:96 packetization-mode=1;profile-level-id=42e01f;"
                        "level-asymmetry-allowed=1\r\n");
        h264_fmtp_seen = TRUE;
      }
    }

    if (g_strcmp0(clean, "a=rtpmap:96 H265/90000") == 0) {
      h265_rtpmap_seen = TRUE;
      if (!h265_fmtp_seen) {
        g_string_append(normalized,
                        "a=fmtp:96 profile-id=1;level-id=93;tier-flag=0;"
                        "tx-mode=SRST\r\n");
        h265_fmtp_seen = TRUE;
      }
    }

    g_free(clean);
  }

  g_strfreev(lines);
  if (h264_rtpmap_seen && !h264_fmtp_seen) {
    g_string_append(normalized,
                    "a=fmtp:96 packetization-mode=1;profile-level-id=42e01f;"
                    "level-asymmetry-allowed=1\r\n");
  }
  if (h265_rtpmap_seen && !h265_fmtp_seen) {
    g_string_append(normalized,
                    "a=fmtp:96 profile-id=1;level-id=93;tier-flag=0;"
                    "tx-mode=SRST\r\n");
  }
  return g_string_free(normalized, FALSE);
}

static void on_local_description_set(GstPromise *promise, gpointer user_data) {
  g_printerr("[webrtc-helper] local description set\n");
  gst_promise_unref(promise);
}

static void on_remote_description_set(GstPromise *promise, gpointer user_data) {
  g_printerr("[webrtc-helper] remote answer applied\n");
  gst_promise_unref(promise);
}

static void on_offer_created(GstPromise *promise, gpointer user_data) {
  const GstStructure *reply = gst_promise_get_reply(promise);
  GstWebRTCSessionDescription *offer = NULL;

  if (!reply ||
      !gst_structure_get(reply, "offer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &offer, NULL) ||
      !offer) {
    g_printerr("[webrtc-helper] create-offer returned no SDP\n");
    gst_promise_unref(promise);
    return;
  }

  gchar *sdp = gst_sdp_message_as_text(offer->sdp);
  gchar *normalized_sdp = normalize_offer_sdp_for_browsers(sdp);
  GstPromise *local = gst_promise_new_with_change_func(on_local_description_set, NULL, NULL);

  GstSDPMessage *normalized_msg = NULL;
  GstWebRTCSessionDescription *local_offer = offer;
  if (gst_sdp_message_new(&normalized_msg) == GST_SDP_OK &&
      gst_sdp_message_parse_buffer((const guint8 *)normalized_sdp, strlen(normalized_sdp),
                                   normalized_msg) == GST_SDP_OK) {
    local_offer =
        gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_OFFER, normalized_msg);
  } else {
    g_printerr("[webrtc-helper] failed to parse normalized offer; using raw offer\n");
    if (normalized_msg) {
      gst_sdp_message_free(normalized_msg);
    }
    normalized_msg = NULL;
  }

  g_signal_emit_by_name(webrtc, "set-local-description", local_offer, local);
  protocol_line_1("OFFER", normalized_sdp);

  if (local_offer != offer) {
    gst_webrtc_session_description_free(local_offer);
  }
  g_free(normalized_sdp);
  g_free(sdp);
  gst_webrtc_session_description_free(offer);
  gst_promise_unref(promise);
}

static gboolean make_offer(gpointer user_data) {
  GstPromise *promise = gst_promise_new_with_change_func(on_offer_created, NULL, NULL);
  g_signal_emit_by_name(webrtc, "create-offer", NULL, promise);
  return G_SOURCE_REMOVE;
}

static gboolean schedule_offer(gpointer user_data) {
  if (offer_requested) {
    return G_SOURCE_REMOVE;
  }
  offer_requested = TRUE;
  g_printerr("[webrtc-helper] requesting SDP offer\n");
  return make_offer(user_data);
}

static void on_negotiation_needed(GstElement *element, gpointer user_data) {
  g_printerr("[webrtc-helper] negotiation needed\n");
  g_idle_add(schedule_offer, NULL);
}

static void on_ice_candidate(GstElement *element, guint mlineindex, gchar *candidate,
                             gpointer user_data) {
  if (!candidate || !*candidate) {
    return;
  }
  gchar **parts = g_strsplit(candidate, " ", -1);
  if (parts && parts[0] && parts[4] && parts[5]) {
    g_printerr("[webrtc-helper] local ICE candidate typ=%s addr=%s port=%s\n", parts[0], parts[4],
               parts[5]);
  }
  g_strfreev(parts);
  protocol_line_2("ICE", mlineindex, candidate);
}

static gpointer start_pipeline_thread(gpointer user_data) {
  GstStateChangeReturn result = gst_element_set_state(pipeline, GST_STATE_PLAYING);
  g_printerr("[webrtc-helper] pipeline PLAYING result=%d\n", result);
  return NULL;
}

static void set_answer(const gchar *sdp_text) {
  GstSDPMessage *sdp = NULL;
  if (gst_sdp_message_new(&sdp) != GST_SDP_OK) {
    g_printerr("[webrtc-helper] failed to allocate answer SDP\n");
    return;
  }
  if (gst_sdp_message_parse_buffer((const guint8 *)sdp_text, strlen(sdp_text), sdp) !=
      GST_SDP_OK) {
    g_printerr("[webrtc-helper] failed to parse answer SDP\n");
    gst_sdp_message_free(sdp);
    return;
  }

  GstWebRTCSessionDescription *answer =
      gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_ANSWER, sdp);
  GstPromise *promise = gst_promise_new_with_change_func(on_remote_description_set, NULL, NULL);
  g_signal_emit_by_name(webrtc, "set-remote-description", answer, promise);
  gst_webrtc_session_description_free(answer);
}

static void add_ice_candidate(guint mlineindex, const gchar *candidate) {
  if (!candidate || !*candidate) {
    return;
  }
  g_signal_emit_by_name(webrtc, "add-ice-candidate", mlineindex, candidate);
}

static gboolean stdin_line(GIOChannel *source, GIOCondition condition, gpointer user_data) {
  if (condition & (G_IO_ERR | G_IO_HUP | G_IO_NVAL)) {
    return G_SOURCE_REMOVE;
  }

  gchar *line = NULL;
  gsize len = 0;
  GError *error = NULL;
  GIOStatus status = g_io_channel_read_line(source, &line, &len, NULL, &error);
  if (status == G_IO_STATUS_AGAIN) {
    return G_SOURCE_CONTINUE;
  }
  if (status != G_IO_STATUS_NORMAL || !line) {
    if (error) {
      g_printerr("[webrtc-helper] stdin read error: %s\n", error->message);
      g_error_free(error);
    }
    g_free(line);
    return G_SOURCE_CONTINUE;
  }

  g_strchomp(line);
  if (g_str_has_prefix(line, "ANSWER ")) {
    gsize decoded_len = 0;
    guchar *decoded = g_base64_decode(line + 7, &decoded_len);
    gchar *sdp = g_strndup((const gchar *)decoded, decoded_len);
    set_answer(sdp);
    g_free(sdp);
    g_free(decoded);
  } else if (g_str_has_prefix(line, "ICE ")) {
    gchar **parts = g_strsplit(line, " ", 3);
    if (parts[1] && parts[2]) {
      guint mlineindex = (guint)atoi(parts[1]);
      gsize decoded_len = 0;
      guchar *decoded = g_base64_decode(parts[2], &decoded_len);
      gchar *candidate = g_strndup((const gchar *)decoded, decoded_len);
      add_ice_candidate(mlineindex, candidate);
      g_free(candidate);
      g_free(decoded);
    }
    g_strfreev(parts);
  }

  g_free(line);
  return G_SOURCE_CONTINUE;
}

static void on_ice_connection_state_notify(GObject *object, GParamSpec *pspec, gpointer user_data) {
  GstWebRTCICEConnectionState state = GST_WEBRTC_ICE_CONNECTION_STATE_NEW;
  g_object_get(object, "ice-connection-state", &state, NULL);
  g_printerr("[webrtc-helper] ice-connection-state=%d\n", (gint)state);
}

static void on_peer_connection_state_notify(GObject *object, GParamSpec *pspec, gpointer user_data) {
  GstWebRTCPeerConnectionState state = GST_WEBRTC_PEER_CONNECTION_STATE_NEW;
  g_object_get(object, "connection-state", &state, NULL);
  g_printerr("[webrtc-helper] peer-connection-state=%d\n", (gint)state);
}

static void configure_ice_port_range(void) {
  GObject *ice = NULL;
  g_object_get(webrtc, "ice-agent", &ice, NULL);
  if (!ice) {
    return;
  }
  gint min_port = env_int("WEBRTC_UDP_PORT_MIN", 62001);
  gint max_port = env_int("WEBRTC_UDP_PORT_MAX", 62020);
  gboolean ice_tcp = g_strcmp0(env_str("WEBRTC_ICE_TCP", "1"), "0") != 0;
  gboolean ice_udp = g_strcmp0(env_str("WEBRTC_ICE_UDP", "1"), "0") != 0;
  g_object_set(ice, "min-rtp-port", min_port, "max-rtp-port", max_port, "ice-tcp", ice_tcp,
               "ice-udp", ice_udp, NULL);
  g_printerr("[webrtc-helper] ICE ports %d-%d udp=%d tcp=%d\n", min_port, max_port, ice_udp,
             ice_tcp);
  g_object_unref(ice);
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IOLBF, 0);
  gst_init(&argc, &argv);

  gchar *desc = pipeline_desc();
  if (!desc) {
    return 2;
  }

  GError *error = NULL;
  pipeline = gst_parse_launch(desc, &error);
  g_free(desc);
  if (!pipeline) {
    g_printerr("[webrtc-helper] pipeline parse failed: %s\n", error->message);
    g_error_free(error);
    return 2;
  }

  webrtc = gst_bin_get_by_name(GST_BIN(pipeline), "sendrecv");
  configure_ice_port_range();
  g_signal_connect(webrtc, "notify::ice-connection-state", G_CALLBACK(on_ice_connection_state_notify),
                   NULL);
  g_signal_connect(webrtc, "notify::connection-state", G_CALLBACK(on_peer_connection_state_notify),
                   NULL);
  g_signal_connect(webrtc, "on-negotiation-needed", G_CALLBACK(on_negotiation_needed), NULL);
  g_signal_connect(webrtc, "on-ice-candidate", G_CALLBACK(on_ice_candidate), NULL);

  GIOChannel *stdin_channel = g_io_channel_unix_new(0);
  g_io_channel_set_encoding(stdin_channel, NULL, NULL);
  g_io_channel_set_flags(stdin_channel, G_IO_FLAG_NONBLOCK, NULL);
  g_io_add_watch(stdin_channel, G_IO_IN | G_IO_ERR | G_IO_HUP | G_IO_NVAL, stdin_line, NULL);

  main_loop = g_main_loop_new(NULL, FALSE);
  g_timeout_add(500, schedule_offer, NULL);
  g_thread_unref(g_thread_new("pipeline-state", start_pipeline_thread, NULL));
  g_main_loop_run(main_loop);

  gst_element_set_state(pipeline, GST_STATE_NULL);
  g_io_channel_unref(stdin_channel);
  gst_object_unref(webrtc);
  gst_object_unref(pipeline);
  return 0;
}
