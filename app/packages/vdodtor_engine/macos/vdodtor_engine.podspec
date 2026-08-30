#
# The macOS half of the vdodtor engine.
#
# The engine itself is a plain CMake project in engine/ with no Flutter
# dependency, so the Windows port can reuse it. This pod does two things:
# it drives that CMake build as an Xcode build phase, and it links the result
# together with the vendored LGPL FFmpeg.
#
Pod::Spec.new do |s|
  s.name             = 'vdodtor_engine'
  s.version          = '0.1.0'
  s.summary          = 'vdodtor native engine: decode, composite, encode.'
  s.description      = <<-DESC
FFmpeg demux/decode with VideoToolbox hardware acceleration, a Metal
compositor shared by preview and export, and the FFI surface the Flutter app
drives it through.
                       DESC
  s.homepage         = 'https://github.com/iChintanSoni/vdodtor'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Chintan Soni' => 'ichintansoni@gmail.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.platform      = :osx, '11.0'
  s.swift_version = '5.0'

  # Flutter loads this podspec through a symlink under
  # app/macos/Flutter/ephemeral/.symlinks, and __dir__ does not resolve it —
  # realpath does. macos/ -> vdodtor_engine/ -> packages/ -> app/ -> repo root.
  podspec_dir = File.dirname(File.realpath(__FILE__))
  repo_root  = File.expand_path('../../../..', podspec_dir)
  engine_dir = File.join(repo_root, 'engine')
  ffmpeg_dir = File.join(repo_root, 'third_party', 'ffmpeg')

  unless File.exist?(File.join(ffmpeg_dir, 'include', 'libavcodec', 'avcodec.h'))
    raise "vdodtor: no vendored FFmpeg at #{ffmpeg_dir}. Run tools/build_ffmpeg.sh."
  end

  # CMake writes here; OTHER_LDFLAGS force-loads the archive it produces.
  engine_build = '${PODS_CONFIGURATION_BUILD_DIR}/vdodtor-engine'

  cmake_phase = {
    :name => 'Build vdodtor engine (CMake)',
    :script => <<~SH,
      set -euo pipefail
      ENGINE_SRC="#{engine_dir}"
      BUILD_DIR="#{engine_build}"

      # Match whatever slices Xcode is building right now.
      CMAKE_ARCHS="$(echo "${ARCHS}" | tr ' ' ';')"
      case "${CONFIGURATION}" in
        Debug) BUILD_TYPE=Debug ;;
        *)     BUILD_TYPE=Release ;;
      esac

      CMAKE_BIN="$(command -v cmake || echo /opt/homebrew/bin/cmake)"
      if [ ! -x "${CMAKE_BIN}" ]; then
        echo "error: cmake not found. brew install cmake" >&2
        exit 1
      fi

      "${CMAKE_BIN}" -S "${ENGINE_SRC}" -B "${BUILD_DIR}" \\
        -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \\
        -DCMAKE_OSX_ARCHITECTURES="${CMAKE_ARCHS}" \\
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}" \\
        -DVD_BUILD_TESTS=OFF
      "${CMAKE_BIN}" --build "${BUILD_DIR}" --target vdodtor_engine
    SH
    :execution_position => :before_compile,
    :output_files => ["#{engine_build}/libvdodtor_engine.a"],
  }

  # The FFmpeg dylibs ride inside this framework rather than the app bundle, so
  # embedding the plugin embeds them too, and @loader_path/Frameworks resolves
  # the @rpath install names without the Runner needing to know they exist.
  s.script_phases = [
    cmake_phase,
    {
      :name => 'Embed vendored FFmpeg',
      :script => <<~SH,
        set -euo pipefail
        SRC="#{ffmpeg_dir}/lib"
        DEST="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH:-${CONTENTS_FOLDER_PATH}/Frameworks}"
        mkdir -p "${DEST}"

        # Real files only: the unversioned names in SRC are linker symlinks and
        # nothing at runtime looks for them.
        for lib in "${SRC}"/*.dylib; do
          [ -L "${lib}" ] && continue
          rsync -a --checksum "${lib}" "${DEST}/"
        done

        if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
          for lib in "${DEST}"/*.dylib; do
            codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
              ${OTHER_CODE_SIGN_FLAGS:-} --timestamp=none "${lib}"
          done
        fi
      SH
      :execution_position => :after_compile,
    },
  ]

  s.frameworks = 'Metal', 'CoreVideo', 'CoreMedia', 'VideoToolbox',
                 'AudioToolbox', 'QuartzCore', 'CoreGraphics'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'HEADER_SEARCH_PATHS' =>
      "$(inherited) #{engine_dir}/include #{ffmpeg_dir}/include",
    'LIBRARY_SEARCH_PATHS' => "$(inherited) #{ffmpeg_dir}/lib",
    # The FFmpeg dylibs are copied into the bundle's Frameworks folder by the
    # Runner's embed phase; @loader_path covers the pod framework's own copy.
    'LD_RUNPATH_SEARCH_PATHS' =>
      '$(inherited) @executable_path/../Frameworks @loader_path/Frameworks',
    # Obj-C++ sources do not get Clang module autolinking, so FlutterMacOS is
    # named explicitly. -force_load pulls in the whole engine archive, which is
    # required: nothing in this pod references most of it, and the linker would
    # otherwise drop the symbols Dart looks up at runtime.
    'OTHER_LDFLAGS' => "$(inherited) -framework FlutterMacOS " \
                       "-force_load #{engine_build}/libvdodtor_engine.a " \
                       '-lavformat -lavcodec -lavutil -lswscale -lswresample',
  }
end
