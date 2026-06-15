#define GST_USE_UNSTABLE_API
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static GMainLoop *main_loop;
static GstElement *pipeline;
static GstElement *video_sink;
static GstElement *audio_sink;

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

static void log_factory_status(const gchar *name) {
  g_printerr("[stream-helper] factory %s=%s\n", name, factory_exists(name) ? "present" : "missing");
}

/* When TRUE the pipeline front hands frames to the GPU (vapostproc) for
 * convert/scale/upload and the encoder segment omits its system-memory caps.
 * Measured on the J4125: cuts helper CPU ~40% versus CPU videoconvert. */
static gboolean gpu_front_active = FALSE;
/* VA surface format the GPU front negotiates with the encoder: NV12 for
 * 8-bit encodes, P010_10LE when a 10-bit HEVC encode is requested. */
static const gchar *gpu_front_format = "NV12";

static gboolean gpu_scale_requested(void) {
  return g_strcmp0(env_str("ULTRA_VIDEO_GPU_SCALE", "1"), "0") != 0;
}

static gboolean video_udp_enabled(void) {
  return g_strcmp0(env_str("ULTRA_VIDEO_UDP", "0"), "1") == 0;
}

static gboolean wss_video_enabled(void) {
  if (!video_udp_enabled()) {
    return TRUE;
  }
  return g_strcmp0(env_str("ULTRA_WSS_VIDEO", "0"), "0") != 0;
}

#define OPUS_NATIVE_RATE 48000

static gchar *audio_encoder_desc(gint audio_rate) {
  const gchar *codec = env_str("ULTRA_AUDIO_CODEC", "opus");
  gint bitrate = MAX(env_int("ULTRA_AUDIO_BITRATE", 64000), 1);
  gint frame_ms = MAX(env_int("ULTRA_AUDIO_FRAME_MS", 20), 2);
  if (g_ascii_strcasecmp(codec, "opus") == 0) {
    if (!factory_exists("opusenc")) {
      g_printerr("[stream-helper] no Opus encoder found\n");
      return NULL;
    }
    g_printerr(
        "[stream-helper] using Opus audio encoder opusenc bitrate=%d capture=%d encode=%d\n",
        bitrate, audio_rate, OPUS_NATIVE_RATE);
    if (audio_rate == OPUS_NATIVE_RATE) {
      return g_strdup_printf(
          "opusenc bitrate=%d bitrate-type=0 complexity=0 frame-size=%d "
          "audio-type=restricted-lowdelay inband-fec=false dtx=false",
          bitrate, frame_ms);
    }
    return g_strdup_printf(
        "audioresample ! audio/x-raw,format=S16LE,rate=%d,channels=2 ! "
        "opusenc bitrate=%d bitrate-type=0 complexity=0 frame-size=%d "
        "audio-type=restricted-lowdelay inband-fec=false dtx=false",
        OPUS_NATIVE_RATE, bitrate, frame_ms);
  }

  if (g_ascii_strcasecmp(codec, "pcm") == 0) {
    g_printerr("[stream-helper] using raw PCM audio rate=%d\n", audio_rate);
    return g_strdup_printf("audio/x-raw,format=S16LE,rate=%d,channels=2", audio_rate);
  }

  g_printerr("[stream-helper] unsupported ULTRA_AUDIO_CODEC=%s (use opus or pcm)\n", codec);
  return NULL;
}

static gint audio_output_rate(void) {
  if (g_ascii_strcasecmp(env_str("ULTRA_AUDIO_CODEC", "opus"), "opus") == 0) {
    return OPUS_NATIVE_RATE;
  }
  return env_int("ULTRA_AUDIO_RATE", 44100);
}

static gchar *video_encoder_desc(void) {
  const gchar *codec = env_str("ULTRA_VIDEO_CODEC", "H264");
  gint bitrate = MAX(env_int("ULTRA_VIDEO_BITRATE", 900000) / 1000, 1);
  gint fps = MAX(env_int("ULTRA_VIDEO_FPS", 24), 1);
  gint key_seconds = MAX(env_int("ULTRA_VIDEO_KEYFRAME_SECONDS", 1), 1);
  gint key_distance = fps * key_seconds;
  gboolean require_hw = g_strcmp0(env_str("ULTRA_VIDEO_REQUIRE_HW", "1"), "0") != 0;

  if (g_ascii_strcasecmp(codec, "H264") == 0 || g_ascii_strcasecmp(codec, "AVC") == 0) {
    if (!require_hw && factory_exists("x264enc")) {
      g_printerr("[stream-helper] using software H.264 encoder x264enc\n");
      return g_strdup_printf(
          "video/x-raw,format=I420 ! "
          "x264enc tune=zerolatency bitrate=%d key-int-max=%d speed-preset=ultrafast ! "
          "video/x-h264,profile=constrained-baseline,stream-format=byte-stream,alignment=au ! "
          "h264parse config-interval=-1",
          bitrate, key_distance);
    }
    if (factory_exists("vah264enc")) {
      if (gpu_scale_requested() && factory_exists("vapostproc")) {
        gpu_front_active = TRUE;
        gpu_front_format = "NV12";
        g_printerr("[stream-helper] using hardware H.264 encoder vah264enc with GPU convert/scale (vapostproc)\n");
        return g_strdup_printf(
            "vah264enc bitrate=%d key-int-max=%d b-frames=0 ref-frames=1 cabac=false "
            "dct8x8=false target-usage=7 ! "
            "video/x-h264,profile=constrained-baseline,stream-format=byte-stream,alignment=au ! "
            "h264parse config-interval=-1",
            bitrate, key_distance);
      }
      g_printerr("[stream-helper] using hardware H.264 encoder vah264enc\n");
      return g_strdup_printf(
          "video/x-raw,format=NV12 ! "
          "vah264enc bitrate=%d key-int-max=%d b-frames=0 ref-frames=1 cabac=false "
          "dct8x8=false target-usage=7 ! "
          "video/x-h264,profile=constrained-baseline,stream-format=byte-stream,alignment=au ! "
          "h264parse config-interval=-1",
          bitrate, key_distance);
    }
    if (factory_exists("vaapih264enc")) {
      g_printerr("[stream-helper] using hardware H.264 encoder vaapih264enc\n");
      return g_strdup_printf(
          "video/x-raw,format=NV12 ! "
          "vaapih264enc bitrate=%d key-int-max=%d ! "
          "video/x-h264,profile=constrained-baseline,stream-format=byte-stream,alignment=au ! "
          "h264parse config-interval=-1",
          bitrate, key_distance);
    }
    g_printerr("[stream-helper] no H.264 encoder found\n");
    return NULL;
  }

  if (g_ascii_strcasecmp(codec, "H265") == 0 || g_ascii_strcasecmp(codec, "HEVC") == 0) {
    /* 10-bit encodes feed P010 surfaces into the Main10 entrypoint; both
     * Main and Main10 EncSlice are exposed by the i965 driver on the J4125. */
    gint bit_depth = env_int("ULTRA_VIDEO_BIT_DEPTH", 8);
    const gchar *raw_format = (bit_depth == 10) ? "P010_10LE" : "NV12";
    const gchar *h265_caps = (bit_depth == 10)
        ? "video/x-h265,profile=main-10,stream-format=byte-stream,alignment=au"
        : "video/x-h265,stream-format=byte-stream,alignment=au";
    log_factory_status("qsvh265enc");
    log_factory_status("msdkh265enc");
    log_factory_status("vah265enc");
    log_factory_status("vaapih265enc");
    if (factory_exists("qsvh265enc") || factory_exists("msdkh265enc")) {
      g_printerr("[stream-helper] QSV/MSDK H.265 factory is present but the validated ultra pipeline still uses VA encoders until QSV caps are proven\n");
    }
    if (factory_exists("vah265enc")) {
      if (gpu_scale_requested() && factory_exists("vapostproc")) {
        gpu_front_active = TRUE;
        gpu_front_format = raw_format;
        g_printerr("[stream-helper] using hardware H.265 encoder vah265enc (%d-bit %s) with GPU convert/scale (vapostproc)\n",
                   bit_depth, raw_format);
        return g_strdup_printf(
            "vah265enc bitrate=%d key-int-max=%d ! %s ! h265parse config-interval=-1",
            bitrate, key_distance, h265_caps);
      }
      g_printerr("[stream-helper] using hardware H.265 encoder vah265enc (%d-bit %s)\n",
                 bit_depth, raw_format);
      return g_strdup_printf(
          "video/x-raw,format=%s ! "
          "vah265enc bitrate=%d key-int-max=%d ! %s ! "
          "h265parse config-interval=-1",
          raw_format, bitrate, key_distance, h265_caps);
    }
    if (factory_exists("vaapih265enc")) {
      if (bit_depth == 10) {
        g_printerr("[stream-helper] 10-bit HEVC requires vah265enc; vaapih265enc falls back to 8-bit NV12\n");
      }
      g_printerr("[stream-helper] using hardware H.265 encoder vaapih265enc\n");
      return g_strdup_printf(
          "video/x-raw,format=NV12 ! "
          "vaapih265enc bitrate=%d key-int-max=%d ! "
          "video/x-h265,stream-format=byte-stream,alignment=au ! "
          "h265parse config-interval=-1",
          bitrate, key_distance);
    }
    g_printerr("[stream-helper] no H.265 encoder found\n");
    return NULL;
  }

  g_printerr("[stream-helper] unsupported ULTRA_VIDEO_CODEC=%s (use H264 or H265)\n", codec);
  return NULL;
}

static gchar *pipeline_desc(void) {
  const gchar *display = env_str("DISPLAY", ":1");
  gint pulse_port = env_int("PULSE_TCP_PORT", 4711);
  gint audio_rate = env_int("ULTRA_AUDIO_RATE", 44100);
  gchar *audio_encoder = audio_encoder_desc(audio_rate);
  if (!audio_encoder) {
    return NULL;
  }
  const gchar *audio_queue =
      "queue max-size-buffers=12 max-size-bytes=0 max-size-time=200000000 leaky=no";

  if (video_udp_enabled() && !wss_video_enabled()) {
    g_printerr("[stream-helper] ULTRA_WSS_VIDEO=0 — audio-only WSS; WebRTC owns video capture\n");
  } else if (video_udp_enabled()) {
    g_printerr("[stream-helper] ULTRA_WSS_VIDEO=1 — WSS video active (WebRTC should be idle)\n");
  }

  if (!wss_video_enabled()) {
    gchar *desc = g_strdup_printf(
        "tcpclientsrc host=127.0.0.1 port=%d do-timestamp=true ! "
        "rawaudioparse use-sink-caps=false format=pcm pcm-format=s16le sample-rate=%d num-channels=2 ! "
        "audioconvert ! audio/x-raw,format=S16LE,rate=%d,channels=2 ! "
        "%s ! %s ! "
        "appsink name=asink emit-signals=true max-buffers=12 drop=false sync=false",
        pulse_port, audio_rate, audio_rate, audio_encoder, audio_queue);
    g_free(audio_encoder);
    return desc;
  }

  gchar *encoder = video_encoder_desc();
  if (!encoder) {
    g_free(audio_encoder);
    return NULL;
  }

  gint width = env_int("ULTRA_VIDEO_WIDTH", 1024);
  gint height = env_int("ULTRA_VIDEO_HEIGHT", 768);
  gint fps = env_int("ULTRA_VIDEO_FPS", 24);
  const gchar *video_queue =
      "queue max-size-buffers=1 max-size-bytes=0 max-size-time=0 leaky=downstream";

  gchar *desc;
  if (gpu_front_active) {
    /* Cheap CPU expand (RGB16 -> BGRx), then vapostproc does the expensive
     * convert/scale/upload on the iGPU and feeds VA surfaces zero-copy into
     * the VA encoder. The leaky queue drops stale frames before any
     * conversion work is spent on them. */
    desc = g_strdup_printf(
        "ximagesrc use-damage=false show-pointer=true do-timestamp=true display-name=%s ! "
        "videorate drop-only=true max-rate=%d ! video/x-raw,framerate=%d/1 ! "
        "%s ! videoconvert ! video/x-raw,format=BGRx ! "
        "vapostproc ! video/x-raw(memory:VAMemory),format=%s,width=%d,height=%d ! "
        "%s ! appsink name=vsink emit-signals=true max-buffers=1 drop=true sync=false "
        "tcpclientsrc host=127.0.0.1 port=%d do-timestamp=true ! "
        "rawaudioparse use-sink-caps=false format=pcm pcm-format=s16le sample-rate=%d num-channels=2 ! "
        "audioconvert ! audio/x-raw,format=S16LE,rate=%d,channels=2 ! "
        "%s ! %s ! "
        "appsink name=asink emit-signals=true max-buffers=12 drop=false sync=false",
        display, fps, fps, video_queue, gpu_front_format, width, height, encoder, pulse_port,
        audio_rate, audio_rate, audio_encoder, audio_queue);
  } else {
    desc = g_strdup_printf(
        "ximagesrc use-damage=false show-pointer=true do-timestamp=true display-name=%s ! "
        "videorate drop-only=true max-rate=%d ! videoscale method=nearest-neighbour ! "
        "video/x-raw,width=%d,height=%d,framerate=%d/1 ! videoconvert ! %s ! "
        "%s ! appsink name=vsink emit-signals=true max-buffers=1 drop=true sync=false "
        "tcpclientsrc host=127.0.0.1 port=%d do-timestamp=true ! "
        "rawaudioparse use-sink-caps=false format=pcm pcm-format=s16le sample-rate=%d num-channels=2 ! "
        "audioconvert ! audio/x-raw,format=S16LE,rate=%d,channels=2 ! "
        "%s ! %s ! "
        "appsink name=asink emit-signals=true max-buffers=12 drop=false sync=false",
        display, fps, width, height, fps, video_queue, encoder, pulse_port, audio_rate, audio_rate,
        audio_encoder, audio_queue);
  }

  g_free(encoder);
  g_free(audio_encoder);
  return desc;
}

static void emit_json_line(const gchar *type, gboolean keyframe, guint64 pts_ns,
                           const guchar *data, gsize size) {
  gchar *encoded = g_base64_encode(data, size);
  if (g_strcmp0(type, "video") == 0) {
    printf("{\"type\":\"video\",\"key\":%s,\"ts\":%llu,\"data\":\"%s\"}\n",
           keyframe ? "true" : "false", (unsigned long long)(pts_ns / 1000000ULL), encoded);
  } else {
    printf("{\"type\":\"audio\",\"codec\":\"%s\",\"rate\":%d,\"bitrate\":%d,\"sourceRate\":%d,\"ts\":%llu,\"data\":\"%s\"}\n",
           env_str("ULTRA_AUDIO_CODEC", "opus"), audio_output_rate(),
           env_int("ULTRA_AUDIO_BITRATE", 64000), env_int("ULTRA_AUDIO_RATE", 44100),
           (unsigned long long)(pts_ns / 1000000ULL),
           encoded);
  }
  fflush(stdout);
  g_free(encoded);
}

static GstFlowReturn on_video_sample(GstAppSink *sink, gpointer user_data) {
  GstSample *sample = gst_app_sink_pull_sample(sink);
  if (!sample) {
    return GST_FLOW_OK;
  }

  GstBuffer *buffer = gst_sample_get_buffer(sample);
  GstCaps *caps = gst_sample_get_caps(sample);
  if (!buffer || !caps) {
    gst_sample_unref(sample);
    return GST_FLOW_OK;
  }

  GstMapInfo map;
  if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) {
    gst_sample_unref(sample);
    return GST_FLOW_OK;
  }

  gboolean keyframe = !GST_BUFFER_FLAG_IS_SET(buffer, GST_BUFFER_FLAG_DELTA_UNIT);
  guint64 pts = GST_BUFFER_PTS(buffer);
  if (pts == GST_CLOCK_TIME_NONE) {
    pts = 0;
  }

  emit_json_line("video", keyframe, pts, map.data, map.size);
  gst_buffer_unmap(buffer, &map);
  gst_sample_unref(sample);
  return GST_FLOW_OK;
}

static GstFlowReturn on_audio_sample(GstAppSink *sink, gpointer user_data) {
  GstSample *sample = gst_app_sink_pull_sample(sink);
  if (!sample) {
    return GST_FLOW_OK;
  }

  GstBuffer *buffer = gst_sample_get_buffer(sample);
  if (!buffer) {
    gst_sample_unref(sample);
    return GST_FLOW_OK;
  }

  GstMapInfo map;
  if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) {
    gst_sample_unref(sample);
    return GST_FLOW_OK;
  }

  guint64 pts = GST_BUFFER_PTS(buffer);
  if (pts == GST_CLOCK_TIME_NONE) {
    pts = 0;
  }

  emit_json_line("audio", FALSE, pts, map.data, map.size);
  gst_buffer_unmap(buffer, &map);
  gst_sample_unref(sample);
  return GST_FLOW_OK;
}

static void on_bus_message(GstBus *bus, GstMessage *message, gpointer user_data) {
  switch (GST_MESSAGE_TYPE(message)) {
  case GST_MESSAGE_ERROR: {
    GError *err = NULL;
    gchar *debug = NULL;
    gst_message_parse_error(message, &err, &debug);
    g_printerr("[stream-helper] error: %s\n", err ? err->message : "unknown");
    if (debug && *debug) {
      g_printerr("[stream-helper] debug: %s\n", debug);
    }
    g_clear_error(&err);
    g_free(debug);
    if (main_loop) {
      g_main_loop_quit(main_loop);
    }
    break;
  }
  case GST_MESSAGE_EOS:
    g_printerr("[stream-helper] EOS\n");
    if (main_loop) {
      g_main_loop_quit(main_loop);
    }
    break;
  default:
    break;
  }
}

int main(int argc, char *argv[]) {
  gst_init(&argc, &argv);

  gchar *desc = pipeline_desc();
  if (!desc) {
    return 1;
  }

  GError *error = NULL;
  pipeline = gst_parse_launch(desc, &error);
  g_free(desc);
  if (!pipeline || error) {
    g_printerr("[stream-helper] pipeline parse failed: %s\n", error ? error->message : "unknown");
    g_clear_error(&error);
    return 1;
  }

  video_sink = gst_bin_get_by_name(GST_BIN(pipeline), "vsink");
  audio_sink = gst_bin_get_by_name(GST_BIN(pipeline), "asink");
  if (!audio_sink || (wss_video_enabled() && !video_sink)) {
    g_printerr("[stream-helper] missing appsink elements\n");
    return 1;
  }

  if (video_sink) {
    g_signal_connect(video_sink, "new-sample", G_CALLBACK(on_video_sample), NULL);
  }
  g_signal_connect(audio_sink, "new-sample", G_CALLBACK(on_audio_sample), NULL);

  GstBus *bus = gst_element_get_bus(pipeline);
  gst_bus_add_signal_watch(bus);
  g_signal_connect(bus, "message", G_CALLBACK(on_bus_message), NULL);
  gst_object_unref(bus);

  gst_element_set_state(pipeline, GST_STATE_PLAYING);
  g_printerr("[stream-helper] pipeline playing\n");

  main_loop = g_main_loop_new(NULL, FALSE);
  g_main_loop_run(main_loop);

  gst_element_set_state(pipeline, GST_STATE_NULL);
  if (video_sink) {
    gst_object_unref(video_sink);
  }
  gst_object_unref(audio_sink);
  gst_object_unref(pipeline);
  g_main_loop_unref(main_loop);
  return 0;
}
