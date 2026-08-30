#include "vdodtor/vd_audio.h"

#include <AudioToolbox/AudioToolbox.h>
#include <stdlib.h>
#include <string.h>

// The default output unit, pulling straight from the renderer.
//
// Kept separate from the renderer on purpose: the whole audio path can then be
// tested without a sound card, and a headless export never opens one.
struct VdAudioDevice {
  AudioUnit unit;
  VdAudioRenderer* renderer;
  bool running;
};

// Real-time thread. Everything it calls is lock-free by construction; see
// vd_audio_renderer_pull.
static OSStatus vd_render_callback(void* context,
                                   AudioUnitRenderActionFlags* flags,
                                   const AudioTimeStamp* timestamp,
                                   UInt32 bus, UInt32 frames,
                                   AudioBufferList* io) {
  (void)flags;
  (void)timestamp;
  (void)bus;

  VdAudioDevice* device = (VdAudioDevice*)context;
  if (!io || io->mNumberBuffers < 1) return noErr;

  float* out = (float*)io->mBuffers[0].mData;
  if (!out) return noErr;

  if (!device || !device->renderer) {
    memset(out, 0, (size_t)frames * VD_AUDIO_CHANNELS * sizeof(float));
    return noErr;
  }
  vd_audio_renderer_pull(device->renderer, out, (int32_t)frames);
  return noErr;
}

VdAudioDevice* vd_audio_device_open(VdAudioRenderer* renderer,
                                    int32_t* out_result) {
  if (out_result) *out_result = VD_OK;
  if (!renderer) {
    if (out_result) *out_result = VD_ERR_INVALID_ARG;
    return NULL;
  }

  AudioComponentDescription description = {
      .componentType = kAudioUnitType_Output,
      .componentSubType = kAudioUnitSubType_DefaultOutput,
      .componentManufacturer = kAudioUnitManufacturer_Apple,
      .componentFlags = 0,
      .componentFlagsMask = 0,
  };
  AudioComponent component = AudioComponentFindNext(NULL, &description);
  if (!component) {
    if (out_result) *out_result = VD_ERR_UNSUPPORTED;
    return NULL;
  }

  VdAudioDevice* device = calloc(1, sizeof(VdAudioDevice));
  if (!device) {
    if (out_result) *out_result = VD_ERR_OPEN;
    return NULL;
  }
  device->renderer = renderer;

  if (AudioComponentInstanceNew(component, &device->unit) != noErr) {
    free(device);
    if (out_result) *out_result = VD_ERR_UNSUPPORTED;
    return NULL;
  }

  // Interleaved 32-bit float at the engine's rate. The unit converts to
  // whatever the hardware actually wants, which is the one job it is better
  // at than we would be.
  AudioStreamBasicDescription format = {
      .mSampleRate = VD_AUDIO_SAMPLE_RATE,
      .mFormatID = kAudioFormatLinearPCM,
      .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      .mFramesPerPacket = 1,
      .mChannelsPerFrame = VD_AUDIO_CHANNELS,
      .mBitsPerChannel = 32,
      .mBytesPerFrame = sizeof(float) * VD_AUDIO_CHANNELS,
      .mBytesPerPacket = sizeof(float) * VD_AUDIO_CHANNELS,
  };
  OSStatus status = AudioUnitSetProperty(
      device->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
      &format, sizeof(format));

  AURenderCallbackStruct callback = {
      .inputProc = vd_render_callback,
      .inputProcRefCon = device,
  };
  if (status == noErr) {
    status = AudioUnitSetProperty(device->unit,
                                  kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input, 0, &callback,
                                  sizeof(callback));
  }
  if (status == noErr) status = AudioUnitInitialize(device->unit);

  if (status != noErr) {
    AudioComponentInstanceDispose(device->unit);
    free(device);
    if (out_result) *out_result = VD_ERR_UNSUPPORTED;
    return NULL;
  }

  return device;
}

int32_t vd_audio_device_start(VdAudioDevice* device) {
  if (!device) return VD_ERR_INVALID_ARG;
  if (device->running) return VD_OK;
  if (AudioOutputUnitStart(device->unit) != noErr) return VD_ERR_UNSUPPORTED;
  device->running = true;
  return VD_OK;
}

int32_t vd_audio_device_stop(VdAudioDevice* device) {
  if (!device) return VD_ERR_INVALID_ARG;
  if (!device->running) return VD_OK;
  // Returns once the callback is guaranteed not to be running again, which is
  // what makes it safe to tear the renderer down afterwards.
  if (AudioOutputUnitStop(device->unit) != noErr) return VD_ERR_UNSUPPORTED;
  device->running = false;
  return VD_OK;
}

void vd_audio_device_close(VdAudioDevice* device) {
  if (!device) return;
  vd_audio_device_stop(device);
  AudioUnitUninitialize(device->unit);
  AudioComponentInstanceDispose(device->unit);
  free(device);
}
