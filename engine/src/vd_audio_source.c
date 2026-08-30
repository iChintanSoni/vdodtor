#include "vdodtor/vd_audio.h"

#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>

// Decoded-but-not-yet-returned frames live here between reads. A decoded AAC
// packet is 1024 frames and the device asks for whatever it likes, so the two
// never line up.
#define VD_SOURCE_SPILL_FRAMES 8192

// How far before the target a seek actually lands, so the decoder has run for
// a while before the samples anyone keeps.
//
// A cold decoder and one that has been running produce different output for
// the same packet: AAC carries an encoder delay of around 2112 samples, and
// until that is flushed through, the first frames out are not the file's.
// Seeking short and decoding into the target makes the result depend only on
// the target, which is what "scrubbing is repeatable" requires.
#define VD_SOURCE_PREROLL_TICKS (VD_TICKS_PER_SECOND / 5)  // 200 ms

struct VdAudioSource {
  AVFormatContext* fmt;
  AVCodecContext* codec;
  SwrContext* swr;
  AVPacket* packet;
  AVFrame* frame;

  int stream_index;
  VdRational stream_tb;
  VdTick duration;

  // Interleaved stereo float, `spill_frames` valid starting at `spill_read`.
  float* spill;
  int32_t spill_frames;
  int32_t spill_read;

  // Position is derived, never accumulated. Adding a rounded tick delta per
  // read drifts: 373 frames is 932.5 ticks, and rounding that up forty times
  // put the clock 20 ticks ahead of the audio. Counting frames and converting
  // once is exact.
  VdTick seek_position;
  int64_t frames_since_seek;

  // Set by a seek, consumed by the first decode after it. av_seek_frame lands
  // on a packet boundary at or before the target, so the samples between the
  // two have to be thrown away — otherwise the position is a lie by up to a
  // packet, which at 1024 frames is 21 ms of A/V drift.
  VdTick seek_target;
  bool awaiting_seek_target;
  int64_t discard_frames;

  bool eof;
};

static VdTick ticks_of(const VdAudioSource* s, int64_t stream_ts) {
  return vd_ticks_from_stream_time(stream_ts, s->stream_tb);
}

static VdRational rational_of(AVRational r) {
  VdRational out = {r.num, r.den};
  if (out.den < 0) {
    out.num = -out.num;
    out.den = -out.den;
  }
  return out;
}

VdAudioSource* vd_audio_source_open(const char* path, int32_t* out_result) {
  if (out_result) *out_result = VD_OK;
  if (!path) {
    if (out_result) *out_result = VD_ERR_INVALID_ARG;
    return NULL;
  }

  VdAudioSource* s = calloc(1, sizeof(VdAudioSource));
  if (!s) {
    if (out_result) *out_result = VD_ERR_OPEN;
    return NULL;
  }
  s->stream_index = -1;
  s->spill = calloc(VD_SOURCE_SPILL_FRAMES * VD_AUDIO_CHANNELS, sizeof(float));
  s->packet = av_packet_alloc();
  s->frame = av_frame_alloc();
  if (!s->spill || !s->packet || !s->frame) {
    vd_audio_source_close(s);
    if (out_result) *out_result = VD_ERR_OPEN;
    return NULL;
  }

  if (avformat_open_input(&s->fmt, path, NULL, NULL) < 0) {
    vd_audio_source_close(s);
    if (out_result) *out_result = VD_ERR_OPEN;
    return NULL;
  }
  if (avformat_find_stream_info(s->fmt, NULL) < 0) {
    vd_audio_source_close(s);
    if (out_result) *out_result = VD_ERR_NO_STREAMS;
    return NULL;
  }

  const AVCodec* codec = NULL;
  s->stream_index =
      av_find_best_stream(s->fmt, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
  if (s->stream_index < 0 || !codec) {
    // Silent video is ordinary, not broken.
    vd_audio_source_close(s);
    if (out_result) *out_result = VD_ERR_NO_STREAMS;
    return NULL;
  }

  AVStream* stream = s->fmt->streams[s->stream_index];
  s->stream_tb = rational_of(stream->time_base);
  s->duration = stream->duration > 0 && stream->duration != AV_NOPTS_VALUE
                    ? vd_ticks_from_stream_time(stream->duration, s->stream_tb)
                    : 0;

  s->codec = avcodec_alloc_context3(codec);
  if (!s->codec ||
      avcodec_parameters_to_context(s->codec, stream->codecpar) < 0) {
    vd_audio_source_close(s);
    if (out_result) *out_result = VD_ERR_OPEN;
    return NULL;
  }
  s->codec->pkt_timebase = stream->time_base;
  if (avcodec_open2(s->codec, codec, NULL) < 0) {
    vd_audio_source_close(s);
    if (out_result) *out_result = VD_ERR_UNSUPPORTED;
    return NULL;
  }

  // Everything becomes 48 kHz interleaved stereo float on the way in, so the
  // mixer and the device only ever see one format.
  AVChannelLayout out_layout = AV_CHANNEL_LAYOUT_STEREO;
  if (swr_alloc_set_opts2(&s->swr, &out_layout, AV_SAMPLE_FMT_FLT,
                          VD_AUDIO_SAMPLE_RATE, &s->codec->ch_layout,
                          s->codec->sample_fmt, s->codec->sample_rate, 0,
                          NULL) < 0 ||
      swr_init(s->swr) < 0) {
    vd_audio_source_close(s);
    if (out_result) *out_result = VD_ERR_UNSUPPORTED;
    return NULL;
  }

  return s;
}

void vd_audio_source_close(VdAudioSource* s) {
  if (!s) return;
  if (s->swr) swr_free(&s->swr);
  if (s->frame) av_frame_free(&s->frame);
  if (s->packet) av_packet_free(&s->packet);
  if (s->codec) avcodec_free_context(&s->codec);
  if (s->fmt) avformat_close_input(&s->fmt);
  free(s->spill);
  free(s);
}

VdTick vd_audio_source_position(const VdAudioSource* s) {
  if (!s) return 0;
  return s->seek_position +
         vd_scale(s->frames_since_seek, VD_TICKS_PER_SECOND,
                  VD_AUDIO_SAMPLE_RATE);
}

VdTick vd_audio_source_duration(const VdAudioSource* s) {
  return s ? s->duration : 0;
}

int32_t vd_audio_source_seek(VdAudioSource* s, VdTick source_time) {
  if (!s) return VD_ERR_INVALID_ARG;
  if (source_time < 0) source_time = 0;

  VdTick landing = source_time - VD_SOURCE_PREROLL_TICKS;
  if (landing < 0) landing = 0;

  const int64_t ts = vd_stream_time_from_ticks(landing, s->stream_tb);
  if (av_seek_frame(s->fmt, s->stream_index, ts, AVSEEK_FLAG_BACKWARD) < 0) {
    if (av_seek_frame(s->fmt, s->stream_index, 0, AVSEEK_FLAG_BACKWARD) < 0) {
      return VD_ERR_DECODE;
    }
  }
  avcodec_flush_buffers(s->codec);
  // The resampler holds internal state across calls; a seek invalidates it.
  swr_init(s->swr);

  s->spill_frames = 0;
  s->spill_read = 0;
  s->seek_position = source_time;
  s->frames_since_seek = 0;
  s->seek_target = source_time;
  s->awaiting_seek_target = true;
  s->discard_frames = 0;
  s->eof = false;
  return VD_OK;
}

// Decodes one packet's worth into the spill buffer. Returns false at EOF.
static bool fill_spill(VdAudioSource* s) {
  s->spill_read = 0;
  s->spill_frames = 0;

  for (;;) {
    int ret = avcodec_receive_frame(s->codec, s->frame);
    if (ret == 0) {
      // The first packet after a seek says where the seek actually landed,
      // which is how many samples have to be discarded to reach the position
      // the caller asked for.
      if (s->awaiting_seek_target) {
        int64_t pts = s->frame->best_effort_timestamp;
        if (pts == AV_NOPTS_VALUE) pts = s->frame->pts;
        if (pts != AV_NOPTS_VALUE) {
          const VdTick landed = ticks_of(s, pts);
          if (landed < s->seek_target) {
            s->discard_frames =
                vd_scale(s->seek_target - landed, VD_AUDIO_SAMPLE_RATE,
                         VD_TICKS_PER_SECOND);
          }
        }
        s->awaiting_seek_target = false;
      }

      uint8_t* out = (uint8_t*)s->spill;
      const int converted =
          swr_convert(s->swr, &out, VD_SOURCE_SPILL_FRAMES,
                      (const uint8_t**)s->frame->extended_data,
                      s->frame->nb_samples);
      av_frame_unref(s->frame);
      if (converted <= 0) continue;
      s->spill_frames = converted;
      return true;
    }
    if (ret == AVERROR_EOF) {
      // Drain whatever the resampler still holds.
      uint8_t* out = (uint8_t*)s->spill;
      const int flushed =
          swr_convert(s->swr, &out, VD_SOURCE_SPILL_FRAMES, NULL, 0);
      s->eof = true;
      if (flushed > 0) {
        s->spill_frames = flushed;
        return true;
      }
      return false;
    }
    if (ret != AVERROR(EAGAIN)) {
      s->eof = true;
      return false;
    }

    int read = av_read_frame(s->fmt, s->packet);
    if (read == AVERROR_EOF) {
      avcodec_send_packet(s->codec, NULL);
      continue;
    }
    if (read < 0) {
      s->eof = true;
      return false;
    }
    if (s->packet->stream_index != s->stream_index) {
      av_packet_unref(s->packet);
      continue;
    }
    const int sent = avcodec_send_packet(s->codec, s->packet);
    av_packet_unref(s->packet);
    if (sent < 0 && sent != AVERROR(EAGAIN)) {
      s->eof = true;
      return false;
    }
  }
}

int32_t vd_audio_source_read(VdAudioSource* s, float* out, int32_t frames) {
  if (!s || !out || frames <= 0) return 0;

  int32_t written = 0;
  while (written < frames) {
    if (s->spill_read >= s->spill_frames) {
      if (s->eof || !fill_spill(s)) break;
    }

    // Burn off whatever the seek overshot before handing anything back.
    if (s->discard_frames > 0) {
      const int32_t buffered = s->spill_frames - s->spill_read;
      const int32_t drop = s->discard_frames < buffered
                               ? (int32_t)s->discard_frames
                               : buffered;
      s->spill_read += drop;
      s->discard_frames -= drop;
      continue;
    }

    const int32_t have = s->spill_frames - s->spill_read;
    const int32_t want = frames - written;
    const int32_t take = have < want ? have : want;

    memcpy(out + (size_t)written * VD_AUDIO_CHANNELS,
           s->spill + (size_t)s->spill_read * VD_AUDIO_CHANNELS,
           (size_t)take * VD_AUDIO_CHANNELS * sizeof(float));

    s->spill_read += take;
    written += take;
  }

  // Counted, not accumulated: vd_audio_source_position converts this once.
  s->frames_since_seek += written;
  return written;
}
