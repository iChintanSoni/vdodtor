// vd_export.h — the timeline, counted out one frame at a time, into a file.
//
// There is one compositor and one mixer, and this is the other thing that
// drives them. Playback asks "what time is it?" and renders that; an export
// asks for frame 0, then frame 1, then frame 2, and waits as long as each one
// takes. Everything below the clock — the clip list, the decoders, the
// transitions, the grade, the captions, the envelopes, the filters — is the
// same code reached through `vd_engine_render_at` and
// `vd_audio_renderer_render_at`. That is the whole design, and it is the whole
// reason the preview is worth looking at: if the two paths could disagree, the
// thing on screen would stop predicting the thing in the file, which is the
// most corrosive bug a video editor can have.
//
// Two *instances*, though, not two implementations. An export makes its own
// engine rather than borrowing the app's: it renders at its own size — a
// project cut at 1080p and exported at 4K is the same render list through a
// bigger compositor, because nothing in the list is measured in pixels — and
// it must not drag the playhead around under somebody who is still editing.
//
// The output format is the timeline's own `width`, `height` and `frame_rate`.
// A caller exporting at a different size hands over a timeline that says so;
// there is deliberately no second place to write a resolution down.
//
// The encoder is AVFoundation: VideoToolbox's hardware H.264/HEVC behind a
// muxer that writes MP4 the rest of the world can open. FFmpeg is on the way
// *in* and Apple's on the way out, which is not an inconsistency — the vendored
// FFmpeg is LGPL and must stay that way, and an H.264 encoder is exactly the
// part of it that would not be.

#ifndef VD_EXPORT_H
#define VD_EXPORT_H

#include <stdbool.h>
#include <stdint.h>

#include "vdodtor/vd_engine.h"
#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VdExport VdExport;

// What the picture is coded as.
//
// Two, and only two, because they are the two answers to one question: H.264
// plays everywhere and HEVC is half the size. Anything else is a preference
// nobody in this product's audience has. The index crosses the FFI boundary as
// an integer — see `ExportCodec` in the plugin — so append only.
typedef enum {
  VD_CODEC_H264 = 0,
  VD_CODEC_HEVC = 1,
} VdExportCodec;

typedef struct {
  VdExportCodec codec;

  // Bits per second for the picture. 0 asks for vd_export_default_bitrate,
  // which is what every preset uses — a number here is for somebody who knows
  // they want one.
  int64_t video_bitrate;

  // Bits per second for the sound. 0 is 192 kbps, which is transparent enough
  // for AAC-LC at 48 kHz stereo that nobody will hear the difference and small
  // enough that nobody will notice the size.
  int32_t audio_bitrate;

  // False writes no audio track at all. A timeline with nothing that makes a
  // sound gets no track either way — a silent AAC stream is not a courtesy.
  bool include_audio;
} VdExportSettings;

// H.264, default bitrates, sound included.
VD_EXPORT VdExportSettings vd_export_default_settings(void);

// Bits per second this size and rate deserve, per codec.
//
// Bits per pixel per frame rather than a table of presets: a table has to
// guess which sizes anyone will pick, and the whole point of a resolution
// nobody thought of is that nobody thought of it. HEVC gets a lower figure
// because that is what it is for.
//
// This is the same function as `defaultVideoBitrate` in
// app/lib/engine/export_plan.dart, and the two test the same table — the
// `vd_time.c` / `time.dart` arrangement, and here for the reason the audio
// envelopes have it: the encoder writes at this rate and the app *draws* it,
// under the preset picker. A sentence promising 6.2 Mbps over a file written
// at 3.7 is worse than no sentence at all. Change one and you must change the
// other.
VD_EXPORT int64_t vd_export_default_bitrate(VdExportCodec codec, int32_t width,
                                            int32_t height,
                                            VdRational frame_rate);

// Bytes free on the volume `path` is on — the file itself need not exist, only
// its parent directory. -1 when that cannot be answered, which a caller should
// read as "do not warn" rather than as "no room".
VD_EXPORT int64_t vd_export_free_bytes(const char* path);

typedef enum {
  VD_EXPORT_RUNNING = 0,
  VD_EXPORT_DONE = 1,
  VD_EXPORT_CANCELLED = 2,
  VD_EXPORT_FAILED = 3,
} VdExportState;

typedef struct {
  int32_t state;  // VdExportState

  int64_t frames_written;
  int64_t frames_total;

  // Where on the timeline the last written frame was. The number a progress
  // bar over a timeline wants, as opposed to the fraction `frames_written`
  // gives.
  VdTick position;

  // A negative VdResult once `state` is VD_EXPORT_FAILED, VD_OK otherwise.
  int32_t error;

  double elapsed_ms;
} VdExportProgress;

// Starts writing `timeline` to `path`, and returns as soon as the file is open
// and the first frame has somewhere to go.
//
// Everything that can be known immediately is decided before this returns —
// an unwritable path, a frame rate the timebase cannot express, a timeline of
// no length — so a caller gets a real error rather than a job that fails a
// second later for a reason it has to poll for. What happens after that
// happens on a thread of the export's own, at whatever speed the machine
// manages.
//
// `timeline` is copied; the caller keeps its own memory.
VD_EXPORT VdExport* vd_export_start(const VdTimeline* timeline,
                                    const char* path, VdExportSettings settings,
                                    int32_t* out_result);

// Where it has got to. Cheap enough to call from a repainting progress bar.
VD_EXPORT void vd_export_progress(VdExport* handle, VdExportProgress* out);

// Asks it to stop. Returns immediately; the state reaches VD_EXPORT_CANCELLED
// once the thread notices, which is within a frame.
VD_EXPORT void vd_export_cancel(VdExport* handle);

// Joins the thread and frees everything.
//
// **A cancelled or failed export leaves no file.** Half a video is worse than
// none: it plays, it looks like the export worked, and the part that is missing
// is the end — which is the part nobody checks. So the partial file is deleted
// here rather than left for the user to find, and destroying an export that is
// still running cancels it first.
VD_EXPORT void vd_export_destroy(VdExport* handle);

#ifdef __cplusplus
}
#endif
#endif  // VD_EXPORT_H
