#include "vdodtor/vd_probe.h"

#include <math.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/display.h>
#include <libavutil/rational.h>

static void copy_name(char* dst, size_t cap, const char* src) {
  if (!src) {
    dst[0] = '\0';
    return;
  }
  size_t n = strlen(src);
  if (n >= cap) n = cap - 1;
  memcpy(dst, src, n);
  dst[n] = '\0';
}

static VdRational from_av(AVRational r) {
  VdRational out = {r.num, r.den};
  if (out.den < 0) {
    out.num = -out.num;
    out.den = -out.den;
  }
  return out;
}

// Rotation lives in a display matrix attached to the stream's codec
// parameters. FFmpeg reports it as a counter-clockwise angle in degrees;
// the document model wants a clockwise 0/90/180/270.
static int32_t rotation_of(const AVStream* stream) {
  const AVPacketSideData* sd = av_packet_side_data_get(
      stream->codecpar->coded_side_data, stream->codecpar->nb_coded_side_data,
      AV_PKT_DATA_DISPLAYMATRIX);
  if (!sd || sd->size < 9 * sizeof(int32_t)) return 0;

  // av_display_rotation_get returns the counter-clockwise angle the matrix
  // encodes; negating it gives the clockwise rotation to apply for correct
  // display, which is the convention the document model uses. This is the
  // same transform ffmpeg's own autorotate performs.
  double theta = -av_display_rotation_get((const int32_t*)sd->data);
  if (isnan(theta)) return 0;

  theta = fmod(theta, 360.0);
  if (theta < 0.0) theta += 360.0;

  // Snap to the four right angles; anything else is a shear or a flip that
  // the M1 compositor does not handle, and 0 is the safe reading.
  if (theta > 315.0 || theta <= 45.0) return 0;
  if (theta <= 135.0) return 90;
  if (theta <= 225.0) return 180;
  return 270;
}

// A stream is treated as variable-rate when the container's exact rate
// (r_frame_rate, the smallest rate all timestamps are multiples of) differs
// meaningfully from the average. It is a heuristic — the honest test is
// decoding — but it is the one every editor uses, and it is right on the
// phone footage that actually is VFR.
static bool looks_variable_rate(const AVStream* stream) {
  AVRational exact = stream->r_frame_rate;
  AVRational avg = stream->avg_frame_rate;
  if (exact.num <= 0 || exact.den <= 0) return false;
  if (avg.num <= 0 || avg.den <= 0) return false;

  double e = av_q2d(exact);
  double a = av_q2d(avg);
  if (a <= 0.0) return false;
  // 1% apart is well outside the rounding of any constant-rate container and
  // well inside the spread of real variable-rate capture.
  double drift = (e - a) / a;
  return (drift > 0.01 || drift < -0.01);
}

static VdTick stream_duration_ticks(const AVStream* stream) {
  if (stream->duration == AV_NOPTS_VALUE || stream->duration <= 0) return 0;
  return vd_ticks_from_stream_time(stream->duration, from_av(stream->time_base));
}

int32_t vd_probe_file(const char* path, VdProbeInfo* out) {
  if (!path || !out) return VD_ERR_INVALID_ARG;
  memset(out, 0, sizeof(*out));
  out->frame_rate = (VdRational){0, 1};
  out->pixel_aspect = (VdRational){1, 1};

  AVFormatContext* fmt = NULL;
  if (avformat_open_input(&fmt, path, NULL, NULL) < 0) return VD_ERR_OPEN;

  if (avformat_find_stream_info(fmt, NULL) < 0) {
    avformat_close_input(&fmt);
    return VD_ERR_NO_STREAMS;
  }

  int video_index = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  int audio_index = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);

  if (video_index < 0 && audio_index < 0) {
    avformat_close_input(&fmt);
    return VD_ERR_NO_STREAMS;
  }

  VdTick longest = 0;

  if (video_index >= 0) {
    const AVStream* s = fmt->streams[video_index];
    const AVCodecParameters* par = s->codecpar;
    out->has_video = true;
    out->width = par->width;
    out->height = par->height;
    out->rotation_degrees = rotation_of(s);
    out->variable_frame_rate = looks_variable_rate(s);

    AVRational rate = s->avg_frame_rate.num > 0 ? s->avg_frame_rate
                                                : s->r_frame_rate;
    out->frame_rate = from_av(rate);

    if (par->sample_aspect_ratio.num > 0 && par->sample_aspect_ratio.den > 0) {
      out->pixel_aspect = from_av(par->sample_aspect_ratio);
    }
    copy_name(out->video_codec, sizeof(out->video_codec),
              avcodec_get_name(par->codec_id));

    VdTick d = stream_duration_ticks(s);
    if (d > longest) longest = d;
  }

  if (audio_index >= 0) {
    const AVStream* s = fmt->streams[audio_index];
    const AVCodecParameters* par = s->codecpar;
    out->has_audio = true;
    out->audio_channels = par->ch_layout.nb_channels;
    out->audio_sample_rate = par->sample_rate;
    copy_name(out->audio_codec, sizeof(out->audio_codec),
              avcodec_get_name(par->codec_id));

    VdTick d = stream_duration_ticks(s);
    if (d > longest) longest = d;
  }

  // Container duration is the fallback: some streams carry none of their own.
  if (longest == 0 && fmt->duration != AV_NOPTS_VALUE && fmt->duration > 0) {
    longest = vd_scale(fmt->duration, VD_TICKS_PER_SECOND, AV_TIME_BASE);
  }
  out->duration = longest;

  copy_name(out->format_name, sizeof(out->format_name), fmt->iformat->name);

  avformat_close_input(&fmt);
  return VD_OK;
}

const char* vd_result_string(int32_t result) {
  switch (result) {
    case VD_OK: return "ok";
    case VD_ERR_OPEN: return "could not open the file";
    case VD_ERR_NO_STREAMS: return "the file has no playable audio or video";
    case VD_ERR_INVALID_ARG: return "invalid argument";
    case VD_ERR_UNSUPPORTED: return "unsupported media";
    case VD_ERR_DECODE: return "the file could not be decoded";
    default: return "unknown error";
  }
}
