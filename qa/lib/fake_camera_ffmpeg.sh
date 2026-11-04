#!/bin/sh
# ffmpeg wrapper for the QA synthetic camera (qa_fake_camera in common.sh).
# A V4L2 capture (`-f v4l2 ...`) becomes a 5 fps MJPEG stream of the still
# test card $QA_CAMERA_CARD on stdout; every other call goes to the real
# ffmpeg ($QA_REAL_FFMPEG).
real=${QA_REAL_FFMPEG:-/usr/bin/ffmpeg}
case " $* " in
  *" -f v4l2 "*)
    exec "$real" -hide_banner -loglevel error -nostdin -re -loop 1 -framerate 5 \
      -i "$QA_CAMERA_CARD" -an -c:v mjpeg -q:v 4 -f image2pipe pipe:1 ;;
esac
exec "$real" "$@"
