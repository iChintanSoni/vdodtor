/// Dart surface for the vdodtor native engine.
///
/// The engine is a plain C library (engine/) with no Flutter dependency. This
/// package is the bridge: generated FFI bindings, a Dart-shaped API over them,
/// and the one widget that knows how a Flutter texture has to be driven on
/// macOS. It holds no document knowledge — the app owns the document model and
/// maps to and from these plain types.
library;

export 'src/engine.dart'
    show
        EngineAnimPreset,
        EngineAnimation,
        EngineClip,
        EngineColor,
        EngineShape,
        EngineShapeKind,
        EngineStats,
        EngineTransition,
        EngineTransitionPreset,
        EngineText,
        EngineTextAlign,
        EngineTimeline,
        EngineTransform,
        EngineVolumePoint,
        FitMode,
        PlaybackState,
        PreviewEngine;
export 'src/media_access.dart'
    show GrantedFile, MediaAccess, MediaDrop, ResolvedFile;
export 'src/native.dart' show EngineException;
export 'src/peaks.dart' show NativePeaks, Peaks;
export 'src/preview.dart' show EnginePreview;
export 'src/probe.dart' show NativeProbe, VdodtorEngine;
export 'src/text.dart' show TextFonts;
export 'src/thumbnails.dart' show NativeThumbnail, Thumbnails;
