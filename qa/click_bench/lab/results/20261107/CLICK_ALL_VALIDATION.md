# Click all buttons: workflow validation

This is a separate integration check of the selected-model batch workflow. Its 12 live requests are **not pooled** into the 432 formal model-comparison trials in [RESULTS.md](RESULTS.md). The table below measures browser request-send-to-executed-click time; the formal comparison tables measure backend API duration.

## Live selected-model run

| Measure | Observed result |
|---|---:|
| Model | `gpt-6-luna` |
| Successful / completed | 12 / 12 (100%) |
| Completed / planned | 12 / 12 |
| Total run wall time | 27.006 s |
| Average send → executed click | 2.167 s |
| Minimum send → executed click | 1.753 s |
| Maximum send → executed click | 3.518 s |
| Timing samples | 12 |
| API, invalid-action, and local errors | 0 |

The run used one stable 1920 × 1080 screenshot, seed 3502325187, and `original` image detail. All 12 request IDs were unique; each response reported the requested model and fresh-context protocol. All stored captures and returned input hashes match the exact PNG saved as `click-all-live-input.png`. Every target had one executed click and recorded matching target events. The run summary and all trial records were persisted.

The independent publication check recomputed mean/min/max from per-trial monotonic timestamps, matched them to recorded click events, checked ISO timestamps, verified target bounds and provider/model IDs, and recomputed screenshot and raw-evidence hashes. The app dispatches browser DOM events within its controlled surface; these UI integration events are synthetic. The separate formal benchmark used trusted Chromium CDP input.

## Controlled failure and timing checks

Four independent browser scenarios used 12 mocked API responses, with zero model calls and zero external result writes. An independent DOM listener measured the actual local clicks. Deliberately false provider latency values could not affect the displayed send-to-click measurements. Controlled capture and persistence delays verified the timer boundaries.

| Scenario | Score | Progress | Timing samples | Outcome |
|---|---:|---:|---:|---|
| Mixed hit, miss, API error, move, out-of-bounds, mismatched response | 1/6 | 6/6 | 2 | completed |
| Stop during first request | 1/1 | 1/5 | 1 | stopped |
| Capture failure after one hit at DPR 2 | 1/2 | 2/5 | 1 | error |
| All requests fail | 0/4 | 4/4 | 0 | completed |

The mixed run included the wrong-target click in timing statistics and excluded the four attempts without a click. Stop was activated using trusted CDP input while the first request was in flight. Unattempted buttons were excluded from accuracy. Layout/model controls stayed locked; overlapping requests were rejected; all requests contained only current instruction, screenshot, resolution, model and request ID. Marker-free screenshots remained byte-identical. Schema-2 export/restore preserved the run and timestamps.

## Long-session event-history regression

Review found that slicing the capped 5,000-event global history could lose current-dispatch evidence after the cap was reached. The frontend now collects a separate buffer for each dispatch while retaining the capped history for inspection. A focused two-response mock regression filled the history to its cap, then performed an exact-center click and pointer move. Both were hits; the click retained four events and a measured timing sample, and the move retained one pointer event with zero clicks and no click-time sample. The history stayed at 5,000 throughout.

The live run began with 0 recorded events and added 48, so it was below the cap and unaffected by that defect. Its captured source hash and the fixed source hash are recorded separately; the paid run was not repeated.

## Timing and score definitions

- Accuracy is successful clicks divided by completed attempts. Progress is completed attempts divided by planned buttons.
- Each click timer starts immediately before the request is sent and ends after the observed local click dispatch. Executed misses count as samples. API errors and other attempts without a click have no timing sample.
- Total wall time includes captures, all request waits, gaps and per-trial persistence. Final summary persistence occurs after that timer ends.
- Average, minimum and maximum show the sample count; when there are no clicks, those values are absent rather than zero.

## Evidence

- [click-all-live-integration.json](click-all-live-integration.json): independently verified live summary, sanitized trials, click events and provenance hashes.
- [click-all-independent-qa.json](click-all-independent-qa.json): controlled mixed/error/stop/partial-run evidence and independent event timestamps.
- [click-all-event-cap-regression.json](click-all-event-cap-regression.json): focused post-fix click/move evidence at the full history cap.
- [click-all-live-input.png](click-all-live-input.png) and [click-all-live-result.png](click-all-live-result.png): source screenshot and completed visible run.
- Regenerate the live audit with `report_click_all.py`; no model calls are made. Raw exports remain under `qa/out/click_lab/click_all/`.
