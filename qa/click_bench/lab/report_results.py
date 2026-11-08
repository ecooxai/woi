#!/usr/bin/env python3
"""Publish auditable summaries of the click-lab phases without credentials.

No API calls are made. Raw browser captures and provider traces stay in qa/out;
small reports, sanitized trial data and representative images are copied into
results/<date>. Different fixtures and image policies retain separate tables.
"""
from __future__ import annotations
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import shutil
import time

import benchmark

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def read_phase(root, name):
    folder = root / name
    report = json.loads((folder / "report.json").read_text())
    rows = [json.loads(line) for line in (folder / "rows.jsonl").read_text().splitlines()]
    report["summary"] = benchmark.summarize(rows)
    return report, rows


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sanitized_rows(rows):
    fields = ("model", "kind", "case_id", "expected_action", "target_size", "screenshot_sha256",
              "request_id", "latency_ms", "wall_time_ms", "status", "hit", "coordinate_hit",
              "action_correct", "center_error_px", "actual_event_hit", "trusted_events")
    response_fields = ("action", "x", "y", "resolved_model", "protocol", "error", "error_code",
                       "width", "height", "screen", "usage", "reasoning_effort", "prompt_sha256",
                       "image_detail", "image_detail_policy", "auth_mode", "fresh_context", "image_sha256")
    for row in rows:
        item = {key: row.get(key) for key in fields}
        item["response"] = {key: row["response"].get(key) for key in response_fields}
        item["event_types"] = [event["type"] for event in row.get("events", [])]
        item["events"] = [{key: event.get(key) for key in ("type", "x", "y", "target", "isTrusted")} for event in row.get("events", [])]
        yield item


def rate(hits, trials):
    return f"{hits}/{trials} ({100*hits/trials:.1f}%)" if trials else "—"


def seconds(ms):
    return "—" if ms is None else f"{ms/1000:.2f}"


def counts(rows):
    return {"trials": len(rows), "hits": sum(r["hit"] for r in rows), "misses": sum(r["status"] == "miss" for r in rows),
            "errors": dict(Counter(r["status"] for r in rows if r["status"] not in ("hit", "miss")))}


def publish(args):
    raw, output = Path(args.raw).resolve(), Path(args.out).resolve()
    output.mkdir(parents=True, exist_ok=True)
    baseline_report, baseline = read_phase(raw, "screening")
    native_report, native = read_phase(raw, "screening-original")
    confirmation_report, confirmation = read_phase(raw, args.confirmation_phase)
    baseline_report.update(fixture="standardized", image_policy="high for all models; immutable v1 baseline")
    corrected = native + [r for r in baseline if r["kind"] == "audio"]
    corrected_summary = benchmark.summarize(corrected)
    confirm_summary = benchmark.summarize(confirmation)
    phases = {"screening-high": (baseline_report, baseline, "screening"),
              "screening-original": (native_report, native, "screening-original"),
              "confirmation-ui": (confirmation_report, confirmation, args.confirmation_phase)}
    for name, (report, rows, source) in phases.items():
        report["phase_label"] = name
        report["raw_rows_sha256"] = sha(raw / source / "rows.jsonl")
        report["observed_protocols"] = sorted({str(r["response"].get("protocol")) for r in rows})
        report["observed_prompt_hashes"] = sorted({str(r["response"].get("prompt_sha256")) for r in rows})
        (output / f"{name}-report.json").write_text(json.dumps(report, indent=2) + "\n")
        with (output / f"{name}-trials.jsonl").open("w") as stream:
            for row in sanitized_rows(rows):
                stream.write(json.dumps(row, separators=(",", ":")) + "\n")
    # The corrected screening uses original text and unchanged high-detail audio;
    # it is never pooled with the different interactive-UI confirmation fixture.
    (output / "corrected-screening-summary.json").write_text(json.dumps(corrected_summary, indent=2) + "\n")
    # Ground truth is published for audit/reproduction only, never sent to a model.
    manifest_fields = ("case_id", "fixture", "seed", "width", "height", "css_width", "css_height",
                       "device_pixel_ratio", "instruction", "expected_action", "target_id", "target_label",
                       "target_size", "boxes", "native_targets", "screenshot_sha256", "screen_metadata")
    for label, phase in (("screening", "screening"), ("confirmation-ui", args.confirmation_phase)):
        cases = [json.loads(path.read_text()) for path in sorted((raw / phase / "cases").glob("*.json"))]
        manifest = [{key: case[key] for key in manifest_fields if key in case} for case in cases]
        (output / f"{label}-cases.json").write_text(json.dumps({"scope": "Evaluator ground truth; never included in model requests", "cases": manifest}, indent=2) + "\n")
    all_rows = baseline + native + confirmation
    aliases = [{"model": r["model"], "reported": r["response"].get("resolved_model"), "case": r["case_id"]}
               for r in all_rows if r["response"].get("resolved_model") and r["response"]["resolved_model"] != r["model"]]
    missing_resolved = sum(r["response"].get("resolved_model") is None for r in all_rows)
    details = {name: counts(rows) for name, (_, rows, _) in phases.items()}
    source_files = ("benchmark.py", "test_lab.py", "test_click_all.py", "report_results.py", "report_click_all.py", "adapters.py", "server.py", "app.js", "app.css", "index.html", "launch.py")
    provenance = {
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "baseline_checkpoint": "3d744b8b", "branch": "gpt-6-astra-pro/woi-click-accuracy-lab-20261107",
        "phase_counts": details,
        "release_source_sha256": {name: sha(HERE / name) for name in source_files if (HERE / name).exists()},
        "source_hash_scope": "Final implementation files at report publication; per-phase provider protocol, prompt and immutable row hashes are recorded separately.",
        "raw_rows_sha256": {name: sha(raw / source / "rows.jsonl") for name, (_, _, source) in phases.items()},
        "provider_endpoints": sorted({r["response"].get("endpoint", "") for r in all_rows}),
        "provider_reported_alias_changes": aliases, "responses_missing_resolved_model": missing_resolved,
        "text_input_for_all_audio_trials": True, "speech_recognition_tested": False,
        "screenshot_history_sent": False, "ground_truth_sent_to_models": False,
        "coordinate_execution": "Trusted Chromium CDP events inside isolated benchmark pages; no operating-system input",
    }
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    # Save only one image per tested native size; the full captures remain local.
    for case_id in ("case-000", "case-004", "case-008"):
        shutil.copyfile(raw / "screening/cases" / f"{case_id}.png", output / f"screening-{case_id}.png")
    for case_id in ("ui-case-012", "ui-case-016", "ui-case-020"):
        source = raw / args.confirmation_phase / "cases" / f"{case_id}.png"
        if source.exists():
            shutil.copyfile(source, output / f"confirmation-{case_id}.png")
    failures = []
    for row in confirmation:
        if row["model"] != "gpt-5.6-luna" or row["status"] != "miss":
            continue
        case = json.loads((raw / args.confirmation_phase / "cases" / (row["case_id"] + ".json")).read_text())
        labels = {target["id"]: target["label"] for target in case["native_targets"]}
        event = next((event for event in reversed(row.get("events", [])) if event["type"] in ("mousemove", "click")), {})
        failure = {"model": row["model"], "case_id": row["case_id"], "instruction": case["instruction"],
                   "expected_label": case["target_label"], "actual_label": labels.get(event.get("target")),
                   "prediction": {key: row["response"].get(key) for key in ("action", "x", "y")},
                   "expected_bounds": next(t for t in case["native_targets"] if t["id"] == case["target_id"]),
                   "capture_width": case["width"], "capture_height": case["height"],
                   "screenshot_sha256": case["screenshot_sha256"], "trusted_events": row["trusted_events"],
                   "center_error_px": row["center_error_px"]}
        failures.append(failure)
        shutil.copyfile(raw / args.confirmation_phase / "cases" / (row["case_id"] + ".png"), output / ("confirmation-miss-" + row["case_id"] + ".png"))
    (output / "confirmation-text-misses.json").write_text(json.dumps(failures, indent=2) + "\n")
    # Strong assertions prevent accidentally reporting mismatched reruns as a pair.
    old_pairs = {(r["model"], r["case_id"]): r for r in baseline}
    for row in native:
        previous = old_pairs[(row["model"], row["case_id"])]
        assert row["screenshot_sha256"] == previous["screenshot_sha256"]
        assert row["response"]["prompt_sha256"] == previous["response"]["prompt_sha256"]
        assert row["response"].get("image_detail") == "original"
    original_summary = {r["model"]: r for r in benchmark.summarize(native)}
    high_summary = {r["model"]: r for r in benchmark.summarize(baseline)}
    general_perfect = [r for r in confirm_summary if r["kind"] == "text" and r["hits"] == r["trials"]]
    best_audio = sorted([r for r in confirm_summary if r["kind"] == "audio"], key=lambda r: (-r["hits"], r["latency_median_ms"]))
    parts = ["# WOI click-accuracy lab results — 7 November 2026", "",
             "## Findings", ""]
    if general_perfect:
        label = "The confirmed text model " if len(general_perfect) == 1 else "The confirmed text models "
        parts.append(label + ", ".join(f"**{r['model']}**" for r in general_perfect) +
                     " hit every tested target in the actual ClickLab UI when sent original-detail screenshots. See the separate screening and confirmation counts below.")
    for failure in failures:
        parts.append(f"`{failure['model']}` made a genuine wrong-button {failure['prediction']['action']}: it was asked for **{failure['expected_label']}** and landed on **{failure['actual_label']}**. The trusted browser event and saved source screenshot preserve that miss; it was not retried or removed.")
    if best_audio:
        leaders = [row for row in best_audio if row["hits"] == best_audio[0]["hits"] and row["trials"] == best_audio[0]["trials"]]
        names = " and ".join(f"**{row['model']}**" for row in leaders)
        outcome = " tied at **" if len(leaders) > 1 else " scored **"
        parts.append(names + outcome + rate(leaders[0]["hits"], leaders[0]["trials"]) +
                     "** in actual-UI confirmation. The small median-latency difference does not establish an accuracy winner. Audio models were prompted with text; these measurements isolate screenshot localization, not speech recognition or voice quality.")
    parts.extend(["", "Selecting image detail materially changes the result. Five text candidates missed the four 2560×1440 screenshots under `high` detail; the paired `original` retest uses byte-identical screenshots, the same instructions, the same reasoning effort, and the same system-prompt hash. This is a configuration comparison, not evidence that those text models lack accurate vision.", "",
                  "## Model screening — 12 matched trials per model", "",
                  "Text rows use the corrected v2 `original` policy. Audio rows retain the v1 `high` policy, which is also the v2 policy for Realtime. Each model gets six clicks and six moves over the same three randomized layouts. No accessibility/vision fallback corrects its coordinates.", "",
                  "| Model | Type | Detail | Clicks | Moves | Total hits | Median / p90 seconds | API/output errors |",
                  "|---|---|---|---:|---:|---:|---:|---:|"])
    for row in sorted(corrected_summary, key=lambda r: (r["kind"] != "text", -r["hits"], r["latency_median_ms"])):
        detail = "original" if row["kind"] == "text" else "high"
        parts.append(f"| {row['model']} | {row['kind']} | {detail} | {row['click_hits']}/{row['click_trials']} | {row['move_hits']}/{row['move_trials']} | {rate(row['hits'],row['trials'])} | {seconds(row['latency_median_ms'])} / {seconds(row['latency_p90_ms'])} | {sum(row['errors'].values())} |")
    parts.extend(["", "### Screening by native capture size", "",
                  "| Model | 960×720 | 1280×720 | 2560×1440 |", "|---|---:|---:|---:|"])
    for row in corrected_summary:
        cells = []
        for resolution in ("960x720", "1280x720", "2560x1440"):
            group = row["by_capture_resolution"].get(resolution, {})
            cells.append(f"{group.get('hits',0)}/{group.get('trials',0)}")
        parts.append("| " + row["model"] + " | " + " | ".join(cells) + " |")
    parts.extend(["", "`codex-auto-review` and `gpt-reserve` are retained because the account catalog exposed them and they accepted the requested task. Their measured coordinate behavior does not establish suitability as general conversational model choices.", "",
                  "## Controlled high-detail versus original-detail comparison", "",
                  "| Text model | High detail, all 12 | Original detail, all 12 | High, 2560×1440 | Original, 2560×1440 |",
                  "|---|---:|---:|---:|---:|"])
    for model in original_summary:
        old, new = high_summary[model], original_summary[model]
        high_large = old["by_capture_resolution"].get("2560x1440", {})
        new_large = new["by_capture_resolution"].get("2560x1440", {})
        parts.append(f"| {model} | {old['hits']}/{old['trials']} | {new['hits']}/{new['trials']} | {high_large.get('hits',0)}/{high_large.get('trials',0)} | {new_large.get('hits',0)}/{new_large.get('trials',0)} |")
    parts.extend(["", "In the original high-detail run, Luna's large-image coordinates were approximately 0.82177 times the source coordinates; several other affected text models returned approximately 0.8 times them. The exact browser mapping passed its oracle checks. Earlier repository results used 1600×900 images, while the app's locator caps capture width at 1920 pixels; the new 2560-pixel cases extended that earlier scope.", "",
                  "## Confirmation in the actual ClickLab UI — 30 new trials per selected model", "",
                  "These use the final UI's canvas capture and target elements, a different fixture from screening. Each selected model gets the same 30 screenshots/instructions: 15 clicks and 15 moves. A trusted browser input event must land in the requested element; returning a plausible coordinate alone cannot pass. These counts are kept separate from screening.", "",
                  "| Model | Clicks | Moves | Total hits | Median / p90 seconds | Median / p90 center error, px | API/output errors |",
                  "|---|---:|---:|---:|---:|---:|---:|"])
    for row in confirm_summary:
        median_error = "—" if row['median_error_px'] is None else f"{row['median_error_px']:.2f}"
        p90_error = "—" if row['error_p90_px'] is None else f"{row['error_p90_px']:.2f}"
        parts.append(f"| {row['model']} | {row['click_hits']}/{row['click_trials']} | {row['move_hits']}/{row['move_trials']} | {rate(row['hits'],row['trials'])} | {seconds(row['latency_median_ms'])} / {seconds(row['latency_p90_ms'])} | {median_error} / {p90_error} | {sum(row['errors'].values())} |")
    resolutions = sorted({key for row in confirm_summary for key in row["by_capture_resolution"]}, key=lambda value: int(value.split('x')[0]))
    parts.extend(["", "### Confirmation by native capture size", "",
                  "| Model | " + " | ".join(resolutions) + " |", "|---|" + "---:|"*len(resolutions)])
    for row in confirm_summary:
        cells = [f"{row['by_capture_resolution'].get(key,{}).get('hits',0)}/{row['by_capture_resolution'].get(key,{}).get('trials',0)}" for key in resolutions]
        parts.append("| " + row["model"] + " | " + " | ".join(cells) + " |")
    parts.extend(["", "## Verification and interpretation", "",
                  "- The standardized fixture passed 12/12 oracle actions. The actual UI passed 30/30 oracle actions, with DPR 1 and 2 and both action types.",
                  "- Fifteen independent integrity tests cover fresh requests, fresh and closed Realtime sockets, forbidden history/target fields, finite and in-bounds coordinates, correct action/event scoring, and error denominators. Separate mocked UI checks cover responsive layout, marker-free captures, frozen layouts, stale capture rejection, and clicks versus pointer moves.",
                  "- Each model request contains only its model ID, current instruction, one screenshot, screenshot dimensions, screen metadata, and a fresh request ID. No target rectangles, element list, previous answers, or prior messages are sent.",
                  "- Text requests use one Responses input message, `store:false`, and no prior-response identifier. Each audio trial opens a new Realtime socket and uses `conversation:none` with one text-plus-image input.",
                  "- Predictions outside the image are rejected, never clamped. API failures, malformed outputs, and timeouts are separate from genuine misses. Raw and sanitized trial records preserve all attempted trials.",
                  f"- There were {len(aliases)} provider-reported model-ID substitutions and {missing_resolved} responses without a provider-reported model ID across these {len(all_rows)} formal trials.",
                  "- The comparison tables report backend model-adapter API duration, including creation of a new Realtime connection. They exclude evaluator page replay and click dispatch. Local HTTP request/response median/p90 times are retained separately in JSON; those also stop before evaluator click execution. These are not the new Click all buttons browser-side request-send-to-executed-click measurements. No speech synthesis timing is claimed.",
                  "- These three formal comparison phases contain 432 requests. Any subsequent Click all buttons integration run is a separate workflow check and is not pooled into their scores or timing columns.",
                  "- These are small, controlled button-localization tests. Perfect results on 12 or 30 trials do not establish reliability on arbitrary desktop applications. Wilson 95% intervals are included in JSON.", "",
                  "## Catalog and account scope", "",
                  "The current Codex login exposed ten text candidates through its live catalog. Six Realtime candidates came from Woi's registered audio-model list and were each verified with twelve live trials. The public `/v1/models` listing returned HTTP 403 for missing `api.model.read` scope under this login, so this report does not claim a global inventory of every OpenAI model or availability in other accounts.", "",
                  "`gpt-live-1.1`, `gpt-live-1`, and `gpt-live-1-codex` remain listed in the UI with an explicit unsupported reason: their live frontend does not directly accept the screenshot input tested here. Delegating images to a separate vision model would measure that delegated model, so no direct click score is assigned to these three entries.", "",
                  "Text trials used `https://chatgpt.com/backend-api/codex/responses`; Realtime trials used `wss://api.openai.com/v1/realtime`. Credentials were read server-side and are absent from reports and browser requests.", "",
                  "## Evidence", "",
                  "- `corrected-screening-summary.json`: corrected 16-model comparison.",
                  "- `screening-high-report.json` and `screening-high-trials.jsonl`: immutable all-high baseline.",
                  "- `screening-original-report.json` and `screening-original-trials.jsonl`: paired original-detail text rerun.",
                  "- `confirmation-ui-report.json` and `confirmation-ui-trials.jsonl`: actual-window confirmation, kept separate.",
                  "- `integrity.json`, `ui-integrity.json`, `confirmation-ui-oracle.json`: independent integrity and oracle evidence.",
                  "- `provenance.json`: phase counts, provider endpoints, protocol/prompt/row hashes, and final source hashes.",
                  "- `screening-cases.json` and `confirmation-ui-cases.json`: evaluator-only case manifests, native geometry and screenshot hashes.",
                  "- `confirmation-text-misses.json`: the preserved incorrect text-model action and its expected/actual target.",
                  "- Representative source screenshots are included beside this report. Full captures and provider traces remain under `qa/out/click_lab/benchmark/20261107/`.", ""])
    if (output / "CLICK_ALL_VALIDATION.md").exists():
        parts.extend(["## Click all buttons workflow", "", "The selected-model batch workflow has separate browser-event QA and live integration evidence in [CLICK_ALL_VALIDATION.md](CLICK_ALL_VALIDATION.md). Its request-send-to-executed-click timings and scores are not pooled into the 432 formal model comparison trials above.", ""])
    (output / "RESULTS.md").write_text("\n".join(parts))
    print(json.dumps({"output": str(output), "phases": details, "corrected_screening": corrected_summary, "confirmation": confirm_summary}, indent=2))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", default=str(REPO / "qa/out/click_lab/benchmark/20261107"))
    parser.add_argument("--out", default=str(HERE / "results/20261107"))
    parser.add_argument("--confirmation-phase", default="confirmation-ui")
    publish(parser.parse_args())

if __name__ == "__main__": main()
