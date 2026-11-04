#!/bin/sh
# ffmpeg wrapper for the QA synthetic camera (qa_fake_camera in common.sh).
# In a V4L2 capture (`-f v4l2 ... -i DEVICE ...`) only the input is swapped:
# the still test card $QA_CAMERA_CARD, looped in real time at the requested
# -framerate; the app's own output options (MJPEG copy, frame dropping,
# image2pipe) stay as they are, so CPU and frame rate match a real webcam's
# MJPEG path. Every other call goes to the real ffmpeg ($QA_REAL_FFMPEG).
real=${QA_REAL_FFMPEG:-/usr/bin/ffmpeg}
case " $* " in
  *" -f v4l2 "*) ;;
  *) exec "$real" "$@" ;;
esac
rate=5 n=$#
while [ $n -gt 0 ]; do
  a=$1; shift; n=$((n - 1))
  case $a in
    -f) if [ "$1" = v4l2 ]; then shift; n=$((n - 1)); else set -- "$@" "$a"; fi ;;
    -input_format | -video_size) shift; n=$((n - 1)) ;;
    -framerate) rate=$1; shift; n=$((n - 1)) ;;
    -i) shift; n=$((n - 1)); set -- "$@" -re -loop 1 -framerate "$rate" -i "$QA_CAMERA_CARD" ;;
    *) set -- "$@" "$a" ;;
  esac
done
# the YUYV fallback encodes itself (-c:v mjpeg); the MJPEG path copies
exec "$real" "$@"
