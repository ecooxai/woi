# Voice control matrix

Everything the user can do in Woi's UI, and how the voice model does it. All ops go through
`AppActions` (app/lib/core/app_actions.dart), the same code the buttons run; the tools live in
app/lib/tools/app_tools.dart (`note_control`, `app_control`). Tests: app/test/app_actions_test.dart,
app/test/voice_control_test.dart.

Status: ✓ = existed before, **added** = new in this change, ✗ = not possible by voice (reason given).

## Views and layout

| Action | UI path | Voice tool / op | Status |
|---|---|---|---|
| Show Note / Chat / Terminal / Settings tab | Tab strip, Ctrl+1..4 | `app_control show_view view=note/chat/terminal/settings` | ✓ |
| Note and chat side by side / single | Split toggle | `app_control show_view view=split / single` | ✓ |
| Chat pane width in split view | Drag the pane divider | `app_control set_setting key=chat_pane value=50% / default` | **added** |
| Close Settings (back) | Esc | `show_view` of the target tab | ✓ |
| History drawer (all conversations) | History button | `note_control list` / `switch` | ✓ |

## Notes

| Action | UI path | Voice tool / op | Status |
|---|---|---|---|
| New note | History "New", note tabs | `note_control new` | ✓ |
| New note with a name ("new note called Ideas") | New, then rename | `note_control new title=Ideas` | **added** |
| Rename note | Tab menu | `note_control rename title=... [name=other note]` (result `renamed_to`) | ✓ |
| Delete note | History trash icon (dialog) | `note_control delete [name]` (approval card) | ✓ |
| Switch note | Note tabs / "More" / history | `note_control switch name=title/previous/number` | ✓ |
| List notes | History drawer | `note_control list` | ✓ |
| Add / insert / replace / delete text | Typing | `note_control append/insert/replace/delete_text`, `update_note` | ✓ |
| Format (heading, bold, list, checklist, quote, code...) | Format menu / shortcuts | `note_control replace` (the model rewrites the Markdown) | ✓ (via text edit) |
| Editor undo / redo | Ctrl+Z / Ctrl+Shift+Z | `note_control undo / redo` | ✓ |
| Copy note / line / paragraph / section | Copy menu | `note_control copy what=...` | ✓ |
| Preview / source toggle | Ctrl+Shift+P | — | ✗ view-only widget state inside the editor; no value for a voice user |
| Run line/selection (send to Woi) | Run button | — | ✗ redundant: the user just says it |
| Pin note | — | — | ✗ no such feature in the app (the current note is always pinned to the context) |

## AI edits

| Action | UI path | Voice tool / op | Status |
|---|---|---|---|
| Apply / reject pending edit | Edit card buttons, Enter / Esc | `app_control apply_edit / reject_edit` (also local "apply"/"reject") | ✓ |
| Undo last AI edit ("undo that") | Edit card Undo | `app_control undo_edit` | ✓ |

## Chat and context

| Action | UI path | Voice tool / op | Status |
|---|---|---|---|
| Clear chat history (keep the note) | — | `app_control clear_chat` (approval card, like delete note) | **added** |
| Compact context now | Context meter "Compact now" | `app_control compact` | **added** |
| Interrupt / stop | Esc, Stop button | The user says "stop" (barge-in) | ✓ (pipeline) |
| Send typed message | Input bar | — | ✗ it is the voice channel itself |
| Play a voice message / enlarge screenshot | Message tile | — | ✗ per-message widgets with no stable spoken reference |

## Connection

| Action | UI path | Voice tool / op | Status |
|---|---|---|---|
| Disconnect | — (app quit) | `app_control disconnect`: waits until the spoken confirmation finished (phase not speaking/thinking, max 20 s), then suspends the session; no auto reconnect | **added** |
| Reconnect / fresh session | Status chip Retry, banner Retry | `app_control reconnect` (after the reply) | **added** |
| Connect when offline | Status chip Retry | — | ✗ there is no voice session to hear the request; the disconnect result tells the model to say "click Retry" |
| Usage left | Usage meter | `app_control usage` | ✓ |
| Sign in with ChatGPT / API key / Codex reload | Login screen, Settings | — | ✗ needs a browser / secrets; keys must not be spoken |
| Test connection | Settings button | `reconnect` | ✓ (equivalent) |

## Mic, camera, screen

| Action | UI path | Voice tool / op | Status |
|---|---|---|---|
| Mic mode hands-free / push-to-talk / mute | Mic control | `app_control set_setting key=mic_mode` | ✓ |
| Camera on / off | Camera button | `camera open / close` | ✓ |
| Screenshot | auto | `take_screenshot` | ✓ |
| Screen share (Android) | Share button | — | ✗ needs the system permission dialog |
| Push-to-talk hold | Space | — | ✗ physical gesture |

## Terminal

| Action | UI path | Voice tool / op | Status |
|---|---|---|---|
| New tab | + / Ctrl+Shift+T | `app_control terminal_new` | ✓ |
| Run a command in a tab | Typing | `app_control terminal_run command tab` | ✓ |
| Close tab | x / Ctrl+Shift+W | `app_control terminal_close tab` | ✓ |
| Switch tab | Click tab | `app_control terminal_switch tab` | **added** |
| Rename tab | Tab menu "Rename…" | `app_control terminal_rename tab title` | **added** |

## Media viewer

| Action | UI path | Voice tool / op | Status |
|---|---|---|---|
| Open file / image / video | — | `app_control viewer_open path`, `show_file` | ✓ |
| Close / pause / play / seek | Viewer controls | `app_control viewer_close/pause/play/seek` | ✓ |
| Zoom / fit, preview/source, wrap | Viewer buttons | — | ✗ viewer-window widget state (separate process) |
| Ask about the media | — | `inspect_media` | ✓ |

## Settings (each field)

All via `app_control set_setting key=... value=...`.

| Setting | Key | Status |
|---|---|---|
| Theme | `theme` | ✓ |
| Mic mode | `mic_mode` | ✓ |
| Voice | `voice` | ✓ |
| Voice model / realtime model | `voice_model` | ✓ |
| Compaction threshold | `compaction_threshold` | ✓ |
| Run in terminal | `run_in_terminal` | ✓ |
| AI edit apply delay | `edit_apply_delay` | ✓ |
| Echo cancellation | `echo_cancellation` | ✓ |
| Usage guard percent | `usage_guard` | ✓ |
| Backend (gpt-live / Direct / API key) | `backend` (reconnects after the reply) | **added** |
| Fallback to Direct at the usage limit | `fallback_to_direct` | **added** |
| Compression model | `compression_model` | **added** |
| Delegate model | `delegate_model` | **added** |
| Workspace folder | `workspace` (must exist; "default" clears) | **added** |
| Auto-screenshot | `auto_screenshot` | **added** |
| Screenshot delay | `screenshot_delay` (seconds, 0-4) | **added** |
| Camera replaces screenshot | `camera_replaces_screenshot` | **added** |
| Thinking chime | `thinking_chime` | **added** |
| Confirm shell commands | `confirm_commands` | **added** |
| Chat pane width | `chat_pane` | **added** |
| API key | — | ✗ secret; must not go through speech or transcripts |
| Codex login reload | — | ✗ file/browser flow |
| Screenshot tiers (image counts) | — | ✗ read-only in the UI too |

## Counts

- ✓ existing: 36
- **added**: 19 (plus the matching tool-description and instruction updates)
- ✗ not possible / not useful: 13

## Confirmation and safety

- Every op returns `ok` plus a short `done` / `renamed_to` / `tab` string for the spoken confirmation.
- Destructive ops (`note_control delete`, `app_control clear_chat`) show an approval card without countdown
  (the same `EditReview` card file edits use, `requireApproval: true`); rejecting returns a denied result.
- Session changes (`backend`, `voice`, `voice_model`) and `disconnect` / `reconnect` act only after the reply
  so Woi does not cut off its own audio.
