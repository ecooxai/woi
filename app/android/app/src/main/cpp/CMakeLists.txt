cmake_minimum_required(VERSION 3.22.1)
project(woi_audio_dsp LANGUAGES C CXX)
set(SPEEXDSP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/speexdsp")
add_library(woi_audio_dsp SHARED
  woi_echo.c woi_echo_jni.cpp
  ${SPEEXDSP_DIR}/libspeexdsp/mdf.c
  ${SPEEXDSP_DIR}/libspeexdsp/preprocess.c
  ${SPEEXDSP_DIR}/libspeexdsp/fftwrap.c
  ${SPEEXDSP_DIR}/libspeexdsp/smallft.c
  ${SPEEXDSP_DIR}/libspeexdsp/filterbank.c)
target_include_directories(woi_audio_dsp PRIVATE ${SPEEXDSP_DIR}/include ${SPEEXDSP_DIR}/libspeexdsp)
target_compile_definitions(woi_audio_dsp PRIVATE FLOATING_POINT USE_SMALLFT EXPORT=)
target_compile_options(woi_audio_dsp PRIVATE -O3 -fvisibility=hidden)
set_target_properties(woi_audio_dsp PROPERTIES C_STANDARD 99 CXX_STANDARD 17)
target_link_libraries(woi_audio_dsp m)
