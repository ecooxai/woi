#!/usr/bin/env python3
"""Independent integrity and browser-event checks for the click accuracy lab.

  ../woi/research/.venv/bin/python qa/click_bench/lab/test_lab.py
  ../woi/research/.venv/bin/python qa/click_bench/lab/test_lab.py --browser
"""
from __future__ import annotations

import argparse
import asyncio
import copy
import hashlib
import json
import math
from pathlib import Path
import struct
import tempfile
import unittest

import benchmark as b


def simple_case():
    return {"width": 400, "height": 240, "css_width": 200, "css_height": 120,
            "device_pixel_ratio": 2, "target_id": "target", "expected_action": "click",
            "boxes": [{"id": "target", "x": 40, "y": 30, "w": 30, "h": 20}],
            "instruction": 'Click the button labeled "Target".'}


def events(action="click", target="target", trusted=True):
    rows = [{"type": "mousemove", "x": 55, "y": 40, "target": target, "isTrusted": trusted}]
    if action == "click":
        rows.extend({"type": kind, "x": 55, "y": 40, "target": target, "isTrusted": trusted}
                    for kind in ("mousedown", "mouseup", "click"))
    return rows


class PredictionChecks(unittest.TestCase):
    def test_correct_coordinates_and_real_click_required(self):
        case = simple_case()
        prediction = {"action": "click", "x": 110, "y": 80}
        self.assertTrue(b.score_prediction(case, prediction, events())["hit"])
        self.assertFalse(b.score_prediction(case, prediction, [])["hit"])
        self.assertFalse(b.score_prediction(case, prediction, events(target="other"))["hit"])
        self.assertFalse(b.score_prediction(case, prediction, events(trusted=False))["hit"])

    def test_move_never_counts_a_click(self):
        case = simple_case()
        case["expected_action"] = "move"
        prediction = {"action": "move", "x": 110, "y": 80}
        self.assertTrue(b.score_prediction(case, prediction, events("move"))["hit"])
        self.assertFalse(b.score_prediction(case, prediction, events("click"))["hit"])

    def test_action_mismatch_is_failure_despite_hit(self):
        case = simple_case()
        prediction = {"action": "move", "x": 110, "y": 80}
        result = b.score_prediction(case, prediction, events("move"))
        self.assertTrue(result["coordinate_hit"])
        self.assertFalse(result["action_correct"])
        self.assertFalse(result["hit"])

    def test_out_of_range_never_clamped(self):
        case = simple_case()
        for x, y in ((-1, 80), (400, 80), (110, 240), (110, -1), (5000, 80)):
            result = b.score_prediction(case, {"action": "click", "x": x, "y": y}, events())
            self.assertEqual(result["status"], "out_of_bounds")
            self.assertFalse(result["hit"])

    def test_boolean_nan_string_and_infinite_rejected(self):
        case = simple_case()
        for x in (True, False, "110", None, float("nan"), float("inf")):
            self.assertEqual(b.prediction_status({"action": "click", "x": x, "y": 80}, case), "malformed")
        self.assertEqual(b.prediction_status({"action": "drag", "x": 110, "y": 80}, case), "malformed")

    def test_target_bounds_are_half_open(self):
        case = simple_case()
        prediction = {"action": "click", "x": 140, "y": 80}
        result = b.score_prediction(case, prediction, events())
        self.assertFalse(result["coordinate_hit"])
        prediction["x"] = 139.9
        self.assertTrue(b.score_prediction(case, prediction, events())["coordinate_hit"])

    def test_native_to_css_mapping_is_not_double_scaled(self):
        case = simple_case()
        result = b.score_prediction(case, {"action": "click", "x": 110, "y": 80}, events())
        self.assertEqual((result["css_x"], result["css_y"]), (55, 40))
        self.assertEqual(result["center_error_px"], 0)
        result = b.score_prediction(case, {"action": "click", "x": 120, "y": 80}, events())
        self.assertEqual(result["center_error_px"], 10)

    def test_error_categories_are_not_misses(self):
        examples = {"unsupported image input": "unsupported", "401 unauthorized": "authentication",
                    "model_not_found": "unavailable", "timeout": "timeout", "429 rate limit": "rate_limited"}
        for message, category in examples.items():
            self.assertEqual(b.prediction_status({"error": message}, simple_case()), category)


class IsolationChecks(unittest.TestCase):
    def test_request_contains_only_current_trial_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            raw = b"\x89PNG\r\n\x1a\n" + b"\x00" * 8 + struct.pack(">II", 400, 240)
            path = Path(directory) / "shot.png"
            path.write_bytes(raw)
            case = simple_case()
            case.update({"screenshot_path": str(path), "screenshot_sha256": hashlib.sha256(raw).hexdigest(),
                         "target_label": "Target", "secret_previous_reply": "WRONG HISTORY"})
            first = b.request_payload(case, "test-model")
            second = b.request_payload(case, "test-model")
            self.assertEqual(set(first), b.REQUEST_KEYS)
            self.assertNotEqual(first["request_id"], second["request_id"])
            self.assertNotIn("boxes", first)
            self.assertNotIn("target_id", first)
            self.assertNotIn("seed", first)
            self.assertNotIn("WRONG HISTORY", json.dumps(first))
            self.assertEqual(first["screen"]["devicePixelRatio"], 2)
            self.assertEqual(first["screenshot"], second["screenshot"])
            path.write_bytes(b"changed")
            with self.assertRaises(AssertionError):
                b.request_payload(case, "test-model")

    def test_matched_cases_are_deterministic_balanced_and_varied(self):
        cases = b.make_cases(12)
        self.assertEqual(cases, b.make_cases(12))
        self.assertEqual(sum(c["expected_action"] == "click" for c in cases), 6)
        self.assertEqual(sum(c["expected_action"] == "move" for c in cases), 6)
        self.assertEqual({c["device_pixel_ratio"] for c in cases}, {1, 2})
        self.assertEqual({c["target_size"] for c in cases}, {"small", "normal", "large"})
        self.assertEqual(len({c["case_id"] for c in cases}), 12)
        self.assertTrue(set(c["case_id"] for c in cases).isdisjoint(c["case_id"] for c in b.make_cases(30, 12)))
        for case in cases:
            buttons = case["buttons"]
            self.assertEqual(len(set(x["label"] for x in buttons)), len(buttons))
            for index, first in enumerate(buttons):
                self.assertGreaterEqual(first["x"], 0)
                self.assertLessEqual(first["x"] + first["w"], case["css_width"])
                self.assertGreaterEqual(first["y"], 0)
                self.assertLessEqual(first["y"] + first["h"], case["css_height"])
                for second in buttons[index+1:]:
                    overlap = (first["x"] < second["x"]+second["w"] and second["x"] < first["x"]+first["w"]
                               and first["y"] < second["y"]+second["h"] and second["y"] < first["y"]+first["h"])
                    self.assertFalse(overlap)

    def test_screenshot_header_is_validated(self):
        raw = b"\x89PNG\r\n\x1a\n" + b"\x00" * 8 + struct.pack(">II", 1280, 720)
        self.assertEqual(b.png_dimensions(raw), (1280, 720))
        with self.assertRaises(ValueError):
            b.png_dimensions(b"not an image")

    def test_summary_exposes_error_denominator(self):
        rows = []
        for index, status in enumerate(("hit", "miss", "timeout", "malformed")):
            rows.append({"model": "m", "kind": "text", "status": status, "hit": status == "hit",
                         "expected_action": "click" if index % 2 == 0 else "move",
                         "latency_ms": 100 + index * 10, "center_error_px": 0 if status == "hit" else 20})
        summary = b.summarize(rows)[0]
        self.assertEqual(summary["trials"], 4)
        self.assertEqual(summary["valid_predictions"], 2)
        self.assertEqual(summary["operational_hit_rate"], .25)
        self.assertEqual(summary["accuracy_given_prediction"], .5)
        self.assertEqual(summary["errors"], {"timeout": 1, "malformed": 1})
        self.assertLess(summary["accuracy_wilson_95"][0], .5)
        self.assertGreater(summary["accuracy_wilson_95"][1], .5)


class EndpointIsolationChecks(unittest.TestCase):
    def test_provider_payloads_have_one_current_message_and_no_history(self):
        import adapters
        trial = {"model": "test-model", "instruction": "Move to THIS CURRENT BUTTON", "screenshot": "data:image/png;base64,current",
                 "width": 400, "height": 240, "screen": {"width": 200, "height": 120, "devicePixelRatio": 2}, "request_id": "current"}
        body = adapters.responses_payload(trial, {"reasoning_effort": "low"})
        self.assertEqual(len(body["input"]), 1)
        self.assertFalse(body["store"])
        for key in ("previous_response_id", "conversation", "messages", "prompt_cache_key"):
            self.assertNotIn(key, body)
        session, response = adapters.realtime_payloads(trial)
        self.assertEqual(response["response"]["conversation"], "none")
        self.assertEqual(len(response["response"]["input"]), 1)
        self.assertEqual(response["response"]["output_modalities"], ["text"])
        self.assertNotIn("input", session["session"])
        self.assertEqual(body["input"], response["response"]["input"])
        self.assertIn("THIS CURRENT BUTTON", json.dumps(body))
        self.assertIn("400 x 240", json.dumps(body))
        self.assertIn("200 x 120 CSS", json.dumps(body))

    def test_new_realtime_connection_is_closed_for_each_trial(self):
        import adapters
        from unittest.mock import patch
        connections = []
        class FakeSocket:
            def __init__(self):
                self.sent, self.closed = [], False
                self.events = [{"type": "session.created", "session": {"model": "test-model"}},
                               {"type": "session.updated"},
                               {"type": "response.done", "response": {"status": "completed", "output": [
                                   {"type": "function_call", "name": "screen_action", "arguments": '{"action":"move","x":10,"y":20}'}]}}]
            async def __aenter__(self):
                connections.append(self)
                return self
            async def __aexit__(self, *exc): self.closed = True
            async def send(self, payload): self.sent.append(json.loads(payload))
            async def recv(self): return json.dumps(self.events.pop(0))
        async def run_pair():
            for label in ("FIRST UNIQUE TARGET", "SECOND UNIQUE TARGET"):
                trial = {"model": "test-model", "instruction": label, "screenshot": "data:image/png;base64,current",
                         "width": 400, "height": 240, "screen": {"width": 200, "height": 120, "devicePixelRatio": 2}}
                await adapters.realtime_trial(trial, {}, adapters.Credentials("api", "fake-test-key"))
        with patch("websockets.connect", side_effect=lambda *a, **kw: FakeSocket()):
            asyncio.run(run_pair())
        self.assertEqual(len(connections), 2)
        self.assertIsNot(connections[0], connections[1])
        self.assertTrue(all(c.closed for c in connections))
        for connection in connections:
            self.assertEqual([e["type"] for e in connection.sent], ["session.update", "response.create"])
        self.assertIn("SECOND UNIQUE TARGET", json.dumps(connections[1].sent))
        self.assertNotIn("FIRST UNIQUE TARGET", json.dumps(connections[1].sent))

    def test_endpoint_rejects_ground_truth_and_previous_messages(self):
        import adapters
        # Extra fields are rejected before even decoding the image or calling a provider.
        for key in ("targets", "target_id", "expected_target", "messages", "previous_response_id", "boxes"):
            with self.assertRaises(adapters.LabError) as raised:
                adapters.validate_trial({key: []})
            self.assertEqual(raised.exception.code, "unexpected_fields")


async def ui_checks(url, output):
    output.mkdir(parents=True, exist_ok=True)
    reports = []
    init = r'''(() => {
      const original=window.fetch.bind(window);window.__qaRequests=[];window.__qaResponses=[];window.__qaSaved=[];window.__qaErrors=[];
      addEventListener('error',e=>__qaErrors.push(e.message));addEventListener('unhandledrejection',e=>__qaErrors.push(String(e.reason)));
      window.fetch=async(input,init={})=>{const u=new URL(typeof input==='string'?input:input.url,location.href);
        if(u.pathname==='/api/trial'){const p=JSON.parse(init.body);__qaRequests.push(p);const response=__qaResponses.shift();if(!response)throw new Error('Unplanned QA API call');if(response.delay_ms)await new Promise(r=>setTimeout(r,response.delay_ms));return new Response(JSON.stringify({...response,model:p.model,request_id:p.request_id,fresh_context:true}),{status:200,headers:{'Content-Type':'application/json'}})}
        if(u.pathname==='/api/result'){__qaSaved.push(JSON.parse(init.body));return new Response('{"ok":true}',{status:200,headers:{'Content-Type':'application/json'}})}
        return original(input,init);};
    })();'''
    async with b.Browser(output) as browser:
        cdp = browser.cdp
        await cdp.command("Page.addScriptToEvaluateOnNewDocument", {"source": init})
        for label, width, height, dpr in (("wide", 1440, 1100, 1), ("narrow-dpr2", 780, 1200, 2)):
            await cdp.command("Emulation.setDeviceMetricsOverride", {"width": width, "height": height, "deviceScaleFactor": dpr,
                                "mobile": False, "screenWidth": width, "screenHeight": height})
            await cdp.command("Page.navigate", {"url": url + "/?seed=112233"})
            for _ in range(150):
                try:
                    ready = await cdp.evaluate("!!window.ClickLab && ClickLab.getState().models.length>0")
                except RuntimeError:
                    ready = False
                if ready: break
                await asyncio.sleep(.1)
            else: raise AssertionError("ClickLab UI failed to load its model inventory")
            state = await cdp.evaluate("ClickLab.getState()")
            assert state["models"] and state["selectedModel"]
            counts = await cdp.evaluate("({total:document.querySelectorAll('input[name=model]').length,disabled:document.querySelectorAll('input[name=model]:disabled').length,checked:document.querySelectorAll('input[name=model]:checked').length})")
            assert counts["total"] == len(state["models"]) and counts["checked"] == 1
            assert counts["disabled"] == sum(m.get("available") is False for m in state["models"])
            layout = await cdp.evaluate("ClickLab.setLayout({seed:112233,width:1280,height:480,count:18})")
            first_capture = await cdp.evaluate("ClickLab.capture().screenshot")
            trial_results = []
            for action, index in (("click", 0), ("move", 9)):
                target = layout["targets"][index]
                instruction = f'{"Click" if action == "click" else "Move the pointer to"} the {target["label"]} button.'
                response = {"action": action, "x": target["x"]+target["w"]/2, "y": target["y"]+target["h"]/2, "latency_ms": 17, "usage": {"total_tokens": 1}}
                result = await cdp.evaluate("(async()=>{ClickLab.setInstruction(" + json.dumps(instruction) + ");__qaResponses.push(" + json.dumps(response) + ");return await ClickLab.runTrial();})()")
                assert result["outcome"] == "hit", result
                assert result["execution"]["target_id"] == target["id"]
                assert result["execution"]["click_count"] == (1 if action == "click" else 0)
                assert (await cdp.evaluate("ClickLab.capture().screenshot")) == first_capture, "Marker leaked into next capture"
                trial_results.append(result)
            requests = await cdp.evaluate("__qaRequests")
            assert len(requests) == 2 and requests[0]["request_id"] != requests[1]["request_id"]
            for request in requests:
                assert set(request) == b.REQUEST_KEYS
                assert request["screenshot"] == first_capture
                assert request["screen"]["devicePixelRatio"] == dpr
            assert requests[0]["instruction"] not in json.dumps(requests[1])
            # The current layout must stay frozen for the whole API request.
            target = layout["targets"][4]
            delayed = {"action": "click", "x": target["x"]+target["w"]/2, "y": target["y"]+target["h"]/2, "latency_ms": 150, "delay_ms": 150}
            lock = await cdp.evaluate("(async()=>{__qaResponses.push(" + json.dumps(delayed) + ");const p=ClickLab.runTrial({instruction:" + json.dumps(f'Click {target["label"]}.') + "});let locked=false;try{ClickLab.setLayout({seed:9})}catch{locked=true}const disabled=document.getElementById('randomize').disabled;const result=await p;return {locked,disabled,hit:result.hit};})()")
            assert lock == {"locked": True, "disabled": True, "hit": True}, lock
            stale = await cdp.evaluate("(()=>{const snapshot=ClickLab.capture();ClickLab.setLayout({seed:445566});return ClickLab.executeForTest({action:'click',x:40,y:40},snapshot)})()")
            assert stale.get("stale") and not stale["events"]
            outside = await cdp.evaluate("ClickLab.executeForTest({action:'click',x:1280,y:20})")
            assert outside.get("out_of_bounds") and not outside["events"]
            # Independently generate a real browser click on a hitbox, bypassing
            # the frontend's synthetic event-dispatch helper.
            center = await cdp.evaluate("(()=>{document.getElementById('board-frame').scrollIntoView({block:'nearest'});ClickLab.clearEvents();const e=document.querySelector('#hit-layer button');const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2,id:e.dataset.target}})()")
            for kind in ("mouseMoved", "mousePressed", "mouseReleased"):
                params = {"type": kind, "x": center["x"], "y": center["y"]}
                if kind != "mouseMoved": params.update(button="left", clickCount=1)
                await cdp.command("Input.dispatchMouseEvent", params)
            real_events = await cdp.evaluate("ClickLab.getEvents()")
            assert any(e["type"] == "click" and e.get("target_id") == center["id"] for e in real_events), real_events
            errors = await cdp.evaluate("__qaErrors")
            assert not errors, errors
            # Capture the actual app UI, including the radio inventory and results.
            await cdp.evaluate("scrollTo(0,0);true")
            shot = await cdp.command("Page.captureScreenshot", {"format": "png", "captureBeyondViewport": False})
            import base64
            (output / f"ui-{label}.png").write_bytes(base64.b64decode(shot["data"]))
            reports.append({"viewport": [width,height], "device_pixel_ratio": dpr, "model_radios": counts,
                            "click_hit": True, "move_hit_without_click": True, "unique_requests": True,
                            "request_fields": sorted(b.REQUEST_KEYS), "markers_excluded_from_screenshot": True,
                            "layout_frozen_during_request": True, "stale_capture_rejected": True,
                            "outside_prediction_not_dispatched": True, "independent_cdp_click_observed": True,
                            "javascript_errors": errors})
    (output / "ui-integrity.json").write_text(json.dumps(reports, indent=2)+"\n")
    print(json.dumps({"ui_integrity": reports}, indent=2))


async def browser_checks(output):
    output.mkdir(parents=True, exist_ok=True)
    async with b.Browser(output) as browser:
        cases = b.make_cases(12)
        await b.capture_cases(browser.cdp, cases, output / "cases")
        oracle = await b.oracle_check(browser.cdp, cases)
        # Intentionally wrong action must fail even at the exact target center.
        case = cases[0]
        target = next(x for x in case["boxes"] if x["id"] == case["target_id"])
        wrong = {"action": "move", "x": (target["x"]+target["w"]/2)*case["device_pixel_ratio"],
                 "y": (target["y"]+target["h"]/2)*case["device_pixel_ratio"]}
        wrong_score = await b.execute_prediction(browser.cdp, case, wrong)
        assert wrong_score["coordinate_hit"] and not wrong_score["hit"]
        assert not any(e["type"] == "click" for e in wrong_score["events"])
        outside = await b.execute_prediction(browser.cdp, case, {"action": "click", "x": case["width"], "y": 50})
        assert outside["status"] == "out_of_bounds" and not outside["events"]
        report = {"oracle_hits": sum(r["hit"] for r in oracle), "oracle_trials": len(oracle),
                  "trusted_event_oracle": oracle, "wrong_action_rejected": True,
                  "move_generates_no_click": True, "out_of_bounds_not_dispatched": True,
                  "dpr_values": sorted(set(c["device_pixel_ratio"] for c in cases)),
                  "viewport_css_sizes": sorted(set((c["css_width"], c["css_height"]) for c in cases)),
                  "screenshot_hashes": {c["case_id"]: c["screenshot_sha256"] for c in cases}}
        (output / "browser-integrity.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({k: v for k, v in report.items() if k not in ("trusted_event_oracle", "screenshot_hashes")}, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser", action="store_true")
    parser.add_argument("--ui-url", help="Test the actual lab UI with mocked model answers; makes no paid model requests")
    parser.add_argument("--out", default=str(b.HERE / "results" / b.DATE / "integrity"))
    args = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__)))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if args.browser:
        asyncio.run(browser_checks(Path(args.out)))
    if args.ui_url:
        asyncio.run(ui_checks(args.ui_url.rstrip("/"), Path(args.out) / "ui"))


if __name__ == "__main__":
    main()
