#!/usr/bin/env bash
# Builds the throwaway exec/login spike APK without Gradle (aapt2 + javac + d8 + apksigner).
# Needs ../bin/arm64/codex (run ../fetch_codex.sh arm64 first). Output: out/codexspike.apk
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
BT="$SDK/build-tools/${BUILD_TOOLS:-36.0.0}"
JAR="$SDK/platforms/${PLATFORM:-android-36}/android.jar"
OUT="$HERE/out"; rm -rf "$OUT"; mkdir -p "$OUT/classes" "$OUT/dex" "$OUT/stage/lib/arm64-v8a"
cp "$HERE/../bin/arm64/codex" "$OUT/stage/lib/arm64-v8a/libcodex.so"
"$BT/aapt2" link -o "$OUT/base.apk" -I "$JAR" --manifest "$HERE/AndroidManifest.xml"
javac --release 17 -classpath "$JAR" -d "$OUT/classes" $(find "$HERE/src" -name '*.java')
"$BT/d8" --min-api 29 --lib "$JAR" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')
cp "$OUT/base.apk" "$OUT/unsigned.apk"
# add classes.dex + lib/ (deflated; fine with extractNativeLibs=true). python zipfile: no `zip` needed.
python3 -I - "$OUT/unsigned.apk" "$OUT/dex/classes.dex" "$OUT/stage/lib/arm64-v8a/libcodex.so" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "a", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    z.write(sys.argv[2], "classes.dex")
    z.write(sys.argv[3], "lib/arm64-v8a/libcodex.so")
PY
"$BT/zipalign" -f -P 16 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign --ks "$HOME/.android/debug.keystore" --ks-pass pass:android --key-pass pass:android \
  --out "$OUT/codexspike.apk" "$OUT/aligned.apk"
ls -la "$OUT/codexspike.apk"
