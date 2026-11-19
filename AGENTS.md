# WOI project instructions

## Scope and repository
- Work in this repository; use project context only.
- Read AGENTS.md and agent/continue.md before continuing work.
- Keep source and outputs organized. Preserve unrelated local changes and do not stage existing QA output or private configuration by default.
- Before a new task, snapshot legitimate pre-existing source changes with an explicit commit, then create a dedicated branch named with model, coordinating agent, and task.
- Current task branch: gpt-6-astra-pro/root-luna-agents-audio-context-20261119.
- Use built-in subagents with the same model/settings. The coordinating agent delegates implementation, tests, builds, and release work.

## Application
- Flutter/Dart application under app, supporting Android and Linux.
- Existing README build guidance applies. Do not run Flutter test/analyze while an APK build is running: generated plugin metadata can race.
- Prefer narrow regression coverage for Android assistant/main transitions and context rendering. Preserve existing user preferences, media attachments, and conversation identifiers.
- Never put credentials, private endpoint URLs, captured user audio/images, or generated secret values into source or logs.

## Validation and release
- Record each iteration's observed quality score, checks, build/test duration, and limitations. Do not inflate scores or claim unperformed validation.
- During tests/builds, sample CPU and RAM every second; investigate abnormal runs over five minutes and resource contention before expanding work.
- Current deliverables are a new APK and source merged to main and pushed to GitHub after verification; retain existing Linux support.
- Any new/updated site must be public. If the existing demo3d gallery is updated, include final work and source without changing unrelated gallery content.
- Update agent/continue.md with concrete state and outstanding work. Before replacing an existing continuation, move it to agent/archive with a dated suffix.

## Verified release operation note
- The 0.22.2 application/build/source revision is 50954bdca7d21179df5a1701b069dce9b9267e7d; later documentation-only commits do not change the built app tree.
- After Flutter tests, use the normal documented APK build with pub refresh. A --no-pub shortcut left integration_test registration in a release build during this task.
- Keep native device validation distinct from simulated lifecycle tests, and GUI startup distinct from live-provider end-to-end verification.

## Current Luna task
- Existing configured low-cost model identifier is kCheapModel = gpt-6-luna; resolve model selection from code.
- Automatic app tool delegation covers requested file/note search/edit and Python/Bash actions; track runs and return results.
- Compaction retains latest five user audio messages and summarizes text only.
- Preserve previous Android assistant handoff and rich collapsed context document.
