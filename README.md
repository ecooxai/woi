# Woi — voice-first AI assistant (Linux first)

Stack: Flutter (Dart), Linux and Android. Audio models use gpt-live or realtime;
connect with Codex login or an OpenAI API key. In this app, gpt-live uses Codex login.
See docs/PLAN.md.

## Build

    cd app
    flutter build linux --release
    # Android: install the arm64-v8a APK on 64-bit phones (e.g. the MI 8):
    flutter build apk --release --flavor arm64 --target-platform android-arm64
    adb install -r build/app/outputs/flutter-apk/app-arm64-release.apk

Build the `armv7` flavor with `--target-platform android-arm`, or the `x64`
flavor with `--target-platform android-x64`, for the other supported ABIs.
Use ABI flavors instead of `--split-per-abi`: they also select the embedded
Python native assets and retain the existing per-ABI upgrade version codes.
Don't run `flutter test`/`analyze` while an APK build runs (pub get regenerates
the plugin registrant with dev dependencies and javac fails).

## Audio and chat controls

The microphone button toggles listening on a tap. Hold it to record, then release
to submit. Android records the microphone only and never starts screen sharing
for a held recording. Held recording on Android requires Android 10 or newer.
Linux records microphone plus system audio. A cancelled hold sends nothing. At the two-minute limit, the clip waits for release or cancel.

Status and context usage are compact icons below the text field. Hover or click
status for connection details; click the context ring for usage. Each assistant
reply records its producing session model underneath the message. The camera is
immediately left of the microphone, and the black send button is at the far right.

On Linux, the native WebRTC microphone uses the PipeWire echo-cancelled source
when echo cancellation is enabled. Reconnecting rebuilds missing nodes and waits
for old capture owners to release before reusing audio resources.

On Android, **Phone** retains the communication audio path. **Media** retains
media volume. For direct realtime sessions, the assistant's streamed PCM supplies
a packaged SpeexDSP echo canceller with the bytes accepted by its AudioTrack.
For gpt-live, WebRTC uses software audio processing with the live call's render
stream as its reference and explicit Android constraints. Changing the live
audio route reconnects the call so the next output track uses the selected Media
or Phone attributes. When cancellation is enabled, direct Media sessions keep
microphone transmission active while Woi speaks, allowing interruptions.
Turning cancellation off retains the previous direct-PCM half-duplex protection.
These references cover the assistant's conversation audio. Local MediaPlayer
clips, viewer video, and audio from unrelated Android applications are outside
this cancellation path.

## Settings

Connection begins with **Codex login** or **API**. Codex shows its sign-in status
and account usage immediately below the selector; API shows the saved API-key
field there. Audio models are selected separately in **Model**.
The audio quick choices are **gpt-realtime-2.1** and **gpt-live-1.1**, with more
models in a selector. Text model controls delegated reasoning and longer tasks;
compaction keeps its separate model under Advanced.

Voice offers **Marin** and **Echo** as quick choices and more voices in a selector.
Realtime and gpt-live have distinct supported voice sets. Incompatible choices
are explained instead of silently switching the login, model, or voice. Saved
custom model IDs are retained, and explicit custom live IDs reach the provider
unchanged; unsupported selections return a visible error.

Everyday preferences are grouped together. Timing, compaction tuning, screenshot
quality, workspace, Android routing and diagnostic controls sit in one
**Advanced** section at the bottom, collapsed by default. Search reveals matching
advanced options. Changes persist automatically, including pending text edits
when leaving the page. Editing a saved inactive API key does not reconnect Codex.

## Images and web search

**Model** includes an image model selector, a custom model ID, account-model
refresh, and image quality. The default is `gpt-image-2.6-flare` with `low` quality,
`1024x1024` size and JPG output. The previous default model migrates on load;
custom model choices stay intact. The selected ID is forwarded exactly.
Account-listed models are distinguished from documented candidates; listing a model does not guarantee
that an account can generate with it. Provider rejection is shown without
silently substituting another model.

The `generate_image` tool starts an independent background request. Its status
and completed image appear in the originating conversation. Completion moves the
image to the bottom after any messages sent while it was running. Generation
duration, file size and pixel dimensions are retained with the image and shown
in the large viewer. User messages always display their text before images.

Completed images are also added to model context as real JPEG bytes. Recent
artwork is restored when reconnecting or reopening its chat, and is kept separate
from the screenshot used for pointer coordinates. Follow-up edits call
`generate_image` with `action: edit`; the tool sends the saved source image to
the edit API, optionally selected by `source_message_id`. Without an explicit
ID, edits prefer the latest artwork over automatic screen captures. New image
requests do not silently inherit an edit reference. Original image files remain
unchanged when a JPEG copy is needed for context or editing. If the provider
returns a different size, the app fits the complete image inside the selected canvas without
stretching or cropping; JPG uses white padding. Automatic sizing preserves the
provider's dimensions. The API-key backend uses the Images API; Codex login uses
the native image-generation tool through its Responses endpoint. Access depends on
the selected account and model.

**Web search** is enabled by default under Preferences. The assistant can call
`web_search` for current information. It runs a dedicated live search with the
selected text model and keeps the returned source URLs. Turning it off removes
the tool from the active session and prevents further dispatches. A provider
response without a completed search is reported as a failure.

The camera control is a green circle beside the microphone and becomes darker
while enabled. Linux microphone and send circles are slightly smaller while
retaining full click targets.

**Luna pointer agent** is enabled by default. Click and pointer
movement requests go to a dedicated `gpt-6-luna` agent with a fresh screenshot,
its dimensions and a clear action request. The agent returns a pointer tool call
without prose. It uses no reasoning effort or unrelated chat history. The app
validates the target and coordinates, maps them through that same screenshot,
and cancels pending actions on interruption or chat changes. Disabling the
setting restores the original pointer path.

## Chat and quick keyboard input

Assistant profile icons appear above their messages. User bubbles are white and
assistant bubbles are very pale green in both app themes; their text, links and
metadata use dark foregrounds for readability. User text remains above image
attachments.

Action requests instruct the assistant to call the applicable tool first,
before acknowledgements or explanation. Explicit pointer requests keep the
Luna route, while clear typing and shortcut requests can dispatch directly.
Completed function calls in streamed delegated responses run as soon as their
arguments are complete, without waiting for the final response. Calls remain
ordered, deduplicated and cancellable.

Use `type_text` for literal text and `send_keys` for shortcuts. Examples include
`ctrl+c`, `ctrl+v`, `ctrl+x`, `ctrl+a`, `ctrl+alt+shift+a`, and the sequence
`ctrl+a ctrl+c`. Explicit shortcuts retain every modifier; semantic actions
such as `copy` use the target app's edit behavior. Quoted typing requests such
as `type "Ctrl+C"` remain literal text.

Android 13 and newer can send exact key chords through the existing accessibility
input connection of the selected app. The assistant panel steps aside for the
whole request, and the same route works while Woi is in the background. Literal
text prefers acknowledged edits on the selected readable accessibility target,
including when the keyboard is hidden or Android retains a stale input
connection. It preserves selection and surrounding text, and refuses edits when
hidden content or an unsupported caret operation would make reconstruction unsafe.
Password and opaque editors retain the input-connection path. An explicitly
accessibility-selected editor can receive text without choosing a new field.
The target app, window and editor stay pinned for the request.

Arbitrary key chords still require an input connection. If no editor exists,
Woi requests the keyboard once without clicking or focusing a field and reports
whether Android actually showed it. The `show_keyboard` tool exposes that same
request. It never claims a keyboard is visible just because its policy request
was accepted. Semantic copy, paste, cut and select-all prefer supported
accessibility actions when the entire requested batch can use them. Plain Home/Back and established phone navigation aliases
keep their Android meanings. System navigation and editor shortcuts must be
separate requests.

The `clipboard` tool reads, writes or pastes text. `action: read` returns clipboard
text; `action: write` stores exact text without typing; `action: paste` pastes the
existing clipboard, or writes optional `text` and then pastes it. Empty strings
are preserved. Unambiguous clipboard reads and quoted literal write/paste
commands skip a model round trip. Clipboard text is not read speculatively. A background read on recent Android versions briefly
shows a small Woi window to obtain permitted foreground access, then returns to
the previous app. Non-text clips are not opened or coerced. Stop or a new user
turn prevents a pending clipboard write from continuing into a stale paste.

Android input-connection calls report that input was dispatched; this does not
prove that the receiving app implements a particular shortcut. No new keyboard
selection or permission grant is needed when Woi's existing accessibility service
is already enabled.

## Computer input and Python

Computer input displays a half-transparent light-blue mouse pointer for 120 ms
before an action and keeps the indicator visible for three seconds afterward.
The visual tail does not delay the tool result or the next action. Left clicks
turn the pointer darker blue; right clicks turn it light red. Android positions
the pointer tip at the real click coordinate, accounting for system-bar and
window offsets. On Android, right click means a touch long-press. Keyboard
actions show a half-transparent keyboard icon and the keys at the top right.
User takeover stops further input until a new user request. `move_pointer` positions the pointer without clicking. Linux uses
XInput2 to distinguish physical input from injected events; Android detects touch
takeover through an input-transparent accessibility overlay and outside-touch
watcher. Android external-mouse hover takeover is not currently observed globally.

The `python` tool runs Python 3 code, returns bounded stdout/stderr and exit status,
and enforces a timeout. Assistant instructions require it for calculations. It
uses the existing command-approval preference. Linux uses installed `python3`;
Android embeds CPython 3.11 in a separate worker process and cleans up ordinary
child processes inheriting its private process group. Calls do not share Python
variables. The worker is not a security sandbox for hostile code.

Linux development requires the XInput2 headers (`libxi-dev`) as well as the normal
Flutter/GTK and PipeWire dependencies. Android's embedded Python requires API 24
or later.

## Verification

    cd app
    flutter analyze
    WOI_LIVE=0 flutter test --reporter expanded
    python3 -m unittest discover -s android/app/src/test/python -v

Build the release APK before its native instrumentation APK, without running
Flutter tests or analysis concurrently:

    cd android
    ./gradlew -PwoiTestBuildType=release :app:assembleArm64ReleaseAndroidTest

The native instrumentation exercises embedded Python output, process cleanup,
timeouts, and recovery on a device. See `qa/aec/RECONNECT.md` for the isolated
PipeWire reconnect test, and `qa/control_overlay_native.py` for Linux overlay and
physical-takeover verification on nested displays.
