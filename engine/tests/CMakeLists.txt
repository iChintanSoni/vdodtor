# One executable per test file; ctest runs them. No external test framework:
# the engine's dependency list is FFmpeg and the platform, and it stays that
# way so CI has nothing to fetch.
set(VD_TEST_MEDIA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/media")

# Committed reference frames, and where a failing comparison leaves the actual
# frame and a difference image. The references live in the source tree because
# approving one means reading a diff of the picture in review; the failures
# live in the build tree because they are output, and CI uploads them from
# there when the job goes red.
set(VD_GOLDEN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/golden")
set(VD_GOLDEN_OUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/golden-failures")

# The typeface catalogue the app ships. The engine test reads the same files
# the app bundles, because a font the tests pass with and the app does not have
# is a font nothing checks.
set(VD_FONT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../app/assets/fonts")

foreach(test vd_time_test vd_probe_test vd_decoder_test vd_compositor_test vd_golden_test vd_engine_test vd_audio_test vd_thumbnail_test vd_peaks_test vd_text_test vd_shape_test vd_anim_test)
  add_executable(${test} ${test}.c)
  target_link_libraries(${test} PRIVATE vdodtor_engine)
  target_include_directories(${test} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_compile_definitions(${test}
    PRIVATE VD_TEST_MEDIA_DIR="${VD_TEST_MEDIA_DIR}"
            VD_GOLDEN_DIR="${VD_GOLDEN_DIR}"
            VD_GOLDEN_OUT_DIR="${VD_GOLDEN_OUT_DIR}"
            VD_FONT_DIR="${VD_FONT_DIR}")
  target_compile_options(${test} PRIVATE -Wall -Wextra)
  add_test(NAME ${test} COMMAND ${test})
endforeach()
