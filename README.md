# Woi — voice-first AI assistant (Linux first)

Stack: Flutter (Dart), Linux first; Android/macOS/iOS later. Realtime voice via gpt-live (Codex ChatGPT auth or OpenAI API key).
See docs/PLAN.md.

## Build

    cd app
    flutter build linux --release
    # Android: one APK per ABI (arm64 is ~48 MB vs ~136 MB fat); install the
    # arm64-v8a one on 64-bit phones (e.g. the MI 8):
    flutter build apk --release --split-per-abi --target-platform android-arm64
    adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk

Drop `--target-platform` to get armeabi-v7a/arm64-v8a/x86_64 APKs side by side.
Don't run `flutter test`/`analyze` while an APK build runs (pub get regenerates
the plugin registrant with dev dependencies and javac fails).
