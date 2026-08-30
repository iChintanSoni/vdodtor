# vdodtor native engine.
#
# CMake is the single definition of what the engine is: the macOS Flutter
# plugin drives this same build (see app/macos/), and the Windows port in
# Post-v1 will reuse it with a different compositor backend.
#
#   cmake -S engine -B build/engine -DCMAKE_BUILD_TYPE=Release
#   cmake --build build/engine
#   ctest --test-dir build/engine --output-on-failure
cmake_minimum_required(VERSION 3.24)
project(vdodtor_engine VERSION 0.1.0 LANGUAGES C CXX)

if(APPLE)
  enable_language(OBJCXX)
endif()

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# --- vendored FFmpeg --------------------------------------------------------
# Built by tools/build_ffmpeg.sh: universal, shared, LGPL 2.1, no GPL parts.
set(VD_FFMPEG_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/ffmpeg"
    CACHE PATH "Root of the vendored FFmpeg build")

if(NOT EXISTS "${VD_FFMPEG_ROOT}/include/libavcodec/avcodec.h")
  message(FATAL_ERROR
    "No vendored FFmpeg at ${VD_FFMPEG_ROOT}.\n"
    "Run tools/build_ffmpeg.sh first.")
endif()

add_library(vd_ffmpeg INTERFACE)
target_include_directories(vd_ffmpeg INTERFACE "${VD_FFMPEG_ROOT}/include")
foreach(lib avcodec avformat avutil swresample swscale)
  find_library(VD_LIB_${lib} NAMES ${lib} PATHS "${VD_FFMPEG_ROOT}/lib"
               NO_DEFAULT_PATH REQUIRED)
  target_link_libraries(vd_ffmpeg INTERFACE ${VD_LIB_${lib}})
endforeach()

# --- shaders ----------------------------------------------------------------
# Compiled ahead of time and embedded as bytes. Nothing compiles a shader at
# runtime and nothing goes looking for a .metallib in a bundle.
set(VD_EXTRA_SOURCES "")
if(APPLE)
  find_program(VD_XCRUN xcrun REQUIRED)
  set(VD_METAL_SRC "${CMAKE_CURRENT_SOURCE_DIR}/src/vd_shaders.metal")
  set(VD_METAL_AIR "${CMAKE_CURRENT_BINARY_DIR}/vd_shaders.air")
  set(VD_METAL_LIB "${CMAKE_CURRENT_BINARY_DIR}/vd_shaders.metallib")
  set(VD_METAL_EMBED "${CMAKE_CURRENT_BINARY_DIR}/vd_shaders_metallib.c")

  add_custom_command(OUTPUT "${VD_METAL_AIR}"
    COMMAND "${VD_XCRUN}" -sdk macosx metal -O2 -c "${VD_METAL_SRC}" -o "${VD_METAL_AIR}"
    DEPENDS "${VD_METAL_SRC}" VERBATIM
    COMMENT "Compiling Metal shaders")
  add_custom_command(OUTPUT "${VD_METAL_LIB}"
    COMMAND "${VD_XCRUN}" -sdk macosx metallib "${VD_METAL_AIR}" -o "${VD_METAL_LIB}"
    DEPENDS "${VD_METAL_AIR}" VERBATIM)
  add_custom_command(OUTPUT "${VD_METAL_EMBED}"
    COMMAND "${CMAKE_COMMAND}" -DINPUT=${VD_METAL_LIB} -DOUTPUT=${VD_METAL_EMBED}
            -DSYMBOL=vd_shaders_metallib
            -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/embed_binary.cmake"
    DEPENDS "${VD_METAL_LIB}" "${CMAKE_CURRENT_SOURCE_DIR}/cmake/embed_binary.cmake"
    VERBATIM COMMENT "Embedding vd_shaders.metallib")

  list(APPEND VD_EXTRA_SOURCES "${VD_METAL_EMBED}" src/vd_compositor.mm)
endif()

# --- engine -----------------------------------------------------------------
add_library(vdodtor_engine STATIC
  src/vd_time.c
  src/vd_probe.c
  src/vd_decoder.c
  src/vd_engine.c
  src/vd_audio_source.c
  src/vd_audio_ring.c
  src/vd_audio_renderer.c
  src/vd_audio_device.c
  src/vd_thumbnail.c
  ${VD_EXTRA_SOURCES}
)
target_include_directories(vdodtor_engine
  PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
target_link_libraries(vdodtor_engine PUBLIC vd_ffmpeg)
target_compile_options(vdodtor_engine PRIVATE
  -Wall -Wextra -Wpedantic -Werror=return-type -Wno-unused-parameter)

if(APPLE)
  target_link_libraries(vdodtor_engine PUBLIC
    "-framework CoreVideo" "-framework CoreMedia"
    "-framework VideoToolbox" "-framework Metal" "-framework CoreFoundation"
    "-framework CoreGraphics" "-framework ImageIO" "-framework QuartzCore"
    "-framework Foundation" "-framework AudioToolbox")
endif()

# --- tests ------------------------------------------------------------------
option(VD_BUILD_TESTS "Build engine unit tests" ON)
if(VD_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
