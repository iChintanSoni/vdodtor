# One executable per test file; ctest runs them. No external test framework:
# the engine's dependency list is FFmpeg and the platform, and it stays that
# way so CI has nothing to fetch.
set(VD_TEST_MEDIA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/media")

foreach(test vd_time_test vd_probe_test vd_decoder_test vd_compositor_test vd_engine_test vd_audio_test)
  add_executable(${test} ${test}.c)
  target_link_libraries(${test} PRIVATE vdodtor_engine)
  target_include_directories(${test} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_compile_definitions(${test}
    PRIVATE VD_TEST_MEDIA_DIR="${VD_TEST_MEDIA_DIR}")
  target_compile_options(${test} PRIVATE -Wall -Wextra)
  add_test(NAME ${test} COMMAND ${test})
endforeach()
