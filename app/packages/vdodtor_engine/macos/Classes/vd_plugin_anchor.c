// Anchors the pod: CocoaPods needs at least one compiled source to produce a
// framework, and the engine itself arrives through -force_load of the static
// library CMake builds (see vdodtor_engine.podspec).
//
// The Flutter texture-registry glue will land here in M1's preview work; only
// the plugin registrar can mint a texture id, so that part cannot live in the
// platform-agnostic engine.
#include "vdodtor/vd_probe.h"

// Referenced by the Dart side purely to confirm the library loaded and the
// engine linked, before any heavier call is attempted.
__attribute__((visibility("default"))) int32_t vd_plugin_loaded(void) {
  return 1;
}
