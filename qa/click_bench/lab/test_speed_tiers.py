"""Focused backend contracts; no provider calls or real credentials are used."""
from __future__ import annotations

import base64
import copy
import json
import os
from pathlib import Path
import struct
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib import request, error
import zlib

import adapters as a
import server


def png():
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 16, 16, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress((b'\0' + b'\xff' * 64) * 16)) + chunk(b'IEND', b'')


def trial(**overrides):
    return {'model': 'test-model', 'instruction': 'Click Cedar.',
            'screenshot': 'data:image/png;base64,' + base64.b64encode(png()).decode(),
            'width': 16, 'height': 16, 'screen': {'width': 1280, 'height': 720, 'devicePixelRatio': 1},
            'request_id': 'tier-test', **overrides}


def reply(actual=None):
    result = {'calls': [{'name': 'screen_action', 'arguments': '{"action":"click","x":8,"y":8}'}],
              'resolved_model': 'test-model', 'usage': {'total_tokens': 10}, 'provider_status': 'completed'}
    if actual is not None:
        result['actual_service_tier'] = actual
    return result


class TierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.settings = self.path / 'settings.json'
        self.auth = self.path / 'auth.json'
        self.settings.write_text('{"backendMode":"codex","apiKey":"configured-key-1234"}')
        self.auth.write_text('{"tokens":{"access_token":"codex-token-1234","account_id":"account-test"}}')
        for item in [patch.dict(os.environ, {'WOI_LAB_AUTH': 'auto', 'OPENAI_API_KEY': '', 'WOI_LAB_API_BASE': a.PUBLIC_BASE, 'WOI_LAB_IMAGE_DETAIL': 'auto'}),
                     patch.object(a, 'settings_path', return_value=self.settings), patch.object(a, 'auth_path', return_value=self.auth),
                     patch.object(a, '_connection_mode', None), patch.object(a, '_connection_key', None),
                     patch.object(a, '_connection_revision', 0), patch.object(a, '_active_trials', 0),
                     patch.object(a, 'SECRET_VALUES', set()), patch.object(a, '_catalog', None), patch.object(a, '_catalog_key', None),
                     patch.object(a, '_catalog_time', 0.0), patch.object(a, '_last_status', {})]:
            item.start()
            self.addCleanup(item.stop)
        self.model = {'id': 'test-model', 'available': True, 'transport': 'responses'}
        self.catalog = {'models': [self.model], 'auth': {'mode': 'codex', 'configured': True}}

    def run_mock(self, speed='normal', actual=None, *, exception=None):
        with patch.object(a, 'discover_models', return_value=self.catalog), patch.object(a, 'responses_trial', return_value=reply(actual), side_effect=exception) as provider:
            result = a.run_trial(trial(speed_tier=speed))
        return result, provider

    def test_all_four_wire_values_and_fresh_context(self):
        for mode in ('codex', 'api'):
            a.configure_connection({'auth_mode': mode})
            for speed, wire in [('normal', 'default'), ('fast', 'priority'), ('ultrafast', 'ultrafast'), ('flex', 'flex')]:
                with self.subTest(mode=mode, speed=speed):
                    value = a.validate_trial(trial(speed_tier=speed))
                    body = a.responses_payload(value, {})
                    self.assertEqual(body['service_tier'], wire)
                    self.assertEqual(len(body['input']), 1)
                    self.assertFalse(body['store'])
                    for field in ('history', 'messages', 'previous_response_id', 'api_key', 'connection_revision', 'speed_tier'):
                        self.assertNotIn(field, body)
                    self.assertNotIn('configured-key', json.dumps(body))

    def test_legacy_omission_is_explicit_normal(self):
        value = a.validate_trial(trial())
        self.assertEqual(value['speed_tier'], 'normal')
        self.assertEqual(a.responses_payload(value, {})['service_tier'], 'default')

    def test_invalid_tier_and_connection_revision_rejected(self):
        for bad in ('auto', 'priority', '', None, [], 5):
            with self.subTest(bad=bad), self.assertRaises(a.LabError) as raised:
                a.validate_trial(trial(speed_tier=bad))
            self.assertEqual(raised.exception.code, 'invalid_speed_tier')
        for bad in (-1, True, '0', None):
            with self.assertRaises(a.LabError):
                a.validate_trial(trial(connection_revision=bad))

    def test_requested_and_reported_values_stay_distinct(self):
        for actual, status in [('priority', 'reported'), ('fast', 'reported'), ('default', 'different'), (None, 'unreported')]:
            result, provider = self.run_mock('fast', actual)
            self.assertIsNone(result['error'])
            self.assertEqual(result['requested_service_tier'], 'priority')
            self.assertEqual(result['actual_service_tier'], actual)
            self.assertEqual(result['tier_status'], status)
            provider.assert_called_once()

    def test_codex_flex_attempted_without_fallback(self):
        result, provider = self.run_mock('flex', exception=a.api_error(400, '{"error":{"message":"Unsupported SERVICE_TIER flex"}}'))
        self.assertEqual(provider.call_args.args[0]['speed_tier'], 'flex')
        provider.assert_called_once()
        self.assertEqual(result['error_code'], 'tier_rejected')
        self.assertEqual(result['tier_status'], 'rejected')
        self.assertEqual(result['requested_service_tier'], 'flex')
        self.assertEqual(result['timeout_ms'], 600000)
        self.assertIsNone(result['x'])

    def test_tier_access_denied_is_distinct_from_credentials(self):
        for status in (400, 401, 403, 422):
            self.assertEqual(a.api_error(status, "Ultrafast service tier is unavailable for this account").code, "tier_rejected")
        self.assertEqual(a.api_error(401, "Invalid API key for service_tier request").code, "authentication_error")
        self.assertEqual(a.api_error(403, "Credential has insufficient scope").code, "access_denied")

    def test_rejected_tier_does_not_poison_normal_status(self):
        self.run_mock('normal', 'default')
        self.run_mock('ultrafast', exception=a.LabError('tier_rejected', 'Ultrafast not supported', status=502))
        key = a.credentials_cache_key(a.load_credentials())
        self.assertEqual(a._last_status[(key, 'test-model', 'normal')]['test_status'], 'responded')
        self.assertEqual(a._last_status[(key, 'test-model', 'ultrafast')]['test_status'], 'tier_rejected')

    def test_realtime_non_normal_is_visible_and_does_not_make_call(self):
        self.model['transport'] = 'realtime'
        for speed in ('fast', 'ultrafast', 'flex'):
            with patch.object(a, 'discover_models', return_value=self.catalog), patch.object(a, 'realtime_trial') as provider:
                result = a.run_trial(trial(speed_tier=speed))
            self.assertEqual(result['tier_status'], 'unsupported')
            self.assertEqual(result['error_code'], 'tier_unsupported_transport')
            self.assertIsNone(result['requested_service_tier'])
            provider.assert_not_called()
        session, response = a.realtime_payloads(trial())
        self.assertNotIn('service_tier', session['session'])
        self.assertNotIn('service_tier', response['response'])
        self.assertEqual(response['response']['conversation'], 'none')

    def test_sse_captures_actual_tier_and_flex_timeout(self):
        final = {'type': 'response.completed', 'response': {'status': 'completed', 'model': 'test-model', 'service_tier': 'flex',
                 'output': [{'type': 'function_call', 'name': 'screen_action', 'arguments': '{"action":"click","x":8,"y":8}'}]}}
        class Stream:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def __iter__(self): return iter([b'data: ' + json.dumps(final).encode() + b'\n'])
        with patch.object(a.request, 'urlopen', return_value=Stream()) as mocked:
            value = a.responses_trial(trial(speed_tier='flex'), {}, a.Credentials('api', 'synthetic-key'))
        self.assertEqual(value['actual_service_tier'], 'flex')
        self.assertEqual(mocked.call_args.kwargs['timeout'], 600)
        request_body = json.loads(mocked.call_args.args[0].data.payload)
        self.assertEqual(request_body['service_tier'], 'flex')

    def test_runtime_key_is_memory_only_and_never_returned(self):
        before = self.settings.read_bytes(), self.auth.read_bytes()
        result = a.configure_connection({'auth_mode': 'api', 'api_key': 'temporary-key-5678'})
        self.assertEqual(a.load_credentials().token, 'temporary-key-5678')
        self.assertTrue(result['session_key'])
        self.assertTrue(result['configured'])
        self.assertNotIn('temporary-key-5678', json.dumps(result))
        self.assertEqual(before, (self.settings.read_bytes(), self.auth.read_bytes()))
        self.assertEqual(a.redact('oops temporary-key-5678'), 'oops <redacted>')
        a.configure_connection({'auth_mode': 'codex'})
        self.assertEqual(a.load_credentials().token, 'codex-token-1234')
        a.configure_connection({'auth_mode': 'api'})
        self.assertEqual(a.load_credentials().token, 'temporary-key-5678')
        a.configure_connection({'auth_mode': 'api', 'api_key': ''})
        self.assertEqual(a.load_credentials().token, 'configured-key-1234')
        self.assertFalse(a.connection_status()['session_key'])

    def test_missing_key_can_be_selected_then_configured(self):
        self.settings.write_text('{"backendMode":"codex"}')
        result = a.configure_connection({'auth_mode': 'api'})
        self.assertFalse(result['configured'])
        self.assertEqual(result['auth_mode'], 'api')
        result = a.configure_connection({'auth_mode': 'api', 'api_key': 'temporary-key-5678'})
        self.assertTrue(result['configured'])

    def test_header_injection_and_unexpected_connection_fields_rejected(self):
        for data in ({'auth_mode': 'api', 'api_key': 'key12345\r\nInjected:yes'}, {'auth_mode': 'api', 'api_key': ['bad']},
                     {'auth_mode': 'api', 'api_key': 'short'}, {'auth_mode': 'api', 'api_base': 'http://bad'}, {'auth_mode': 'codex', 'api_key': 'key12345'}):
            with self.assertRaises(a.LabError):
                a.configure_connection(data)
        self.assertEqual(a.connection_status()['revision'], 0)

    def test_connection_cannot_change_during_trial_and_stale_guard_rejects(self):
        with a.connection_lease(0):
            with self.assertRaises(a.LabError) as raised:
                a.configure_connection({'auth_mode': 'api'})
            self.assertEqual(raised.exception.code, 'connection_busy')
        a.configure_connection({'auth_mode': 'api'})
        with self.assertRaises(a.LabError) as raised:
            with a.connection_lease(0): pass
        self.assertEqual(raised.exception.code, 'connection_changed')
        self.assertEqual(a._active_trials, 0)

    def test_catalog_cache_is_scoped_to_connection_and_key(self):
        catalogs = []
        def catalog(url, creds, timeout=20):
            catalogs.append((creds.mode, creds.token))
            return {'models': [{'id': 'test-model', 'input_modalities': ['text', 'image']}]}
        with patch.object(a, 'http_json', side_effect=catalog), patch.object(a, 'app_registered_models', return_value=[]):
            first = a.discover_models()
            self.assertEqual(first['connection']['auth_mode'], 'codex')
            a.configure_connection({'auth_mode': 'api', 'api_key': 'temporary-key-5678'})
            second = a.discover_models()
            self.assertEqual(second['auth']['mode'], 'api')
            self.assertEqual(second['connection']['revision'], 1)
            a.configure_connection({'auth_mode': 'api', 'api_key': 'second-key-901234'})
            third = a.discover_models()
            self.assertEqual(third['connection']['revision'], 2)
            self.assertEqual(catalogs[-1], ('api', 'second-key-901234'))
            self.assertNotIn('second-key-901234', json.dumps(third))

    def test_loopback_connection_endpoint_and_scrub(self):
        app = server.make_server(port=0, output=self.path / 'evidence', discovery=lambda **kw: {'models': []})
        thread = threading.Thread(target=app.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(app.server_close)
        self.addCleanup(app.shutdown)
        base = f'http://127.0.0.1:{app.server_address[1]}'
        data = {'auth_mode': 'api', 'api_key': 'temporary-key-5678'}
        req = request.Request(base + '/api/connection', json.dumps(data).encode(), {'Content-Type': 'application/json'}, method='POST')
        with request.urlopen(req) as response:
            result = json.load(response)
        self.assertTrue(result['configured'])
        self.assertEqual(result['auth_mode'], 'api')
        self.assertNotIn('temporary-key-5678', json.dumps(result))
        self.assertFalse((self.path / 'evidence' / 'trials.jsonl').exists())
        self.assertFalse((self.path / 'evidence' / 'results.jsonl').exists())
        with request.urlopen(base + '/api/connection') as response:
            self.assertEqual(json.load(response)['revision'], 1)
        evil = request.Request(base + '/api/connection', json.dumps(data).encode(), {'Content-Type': 'application/json', 'Origin': 'https://example.test'}, method='POST')
        with self.assertRaises(error.HTTPError) as raised:
            request.urlopen(evil)
        self.assertEqual(raised.exception.code, 403)
        self.assertEqual(server.scrub({'api_key': data['api_key'], 'error': 'oops ' + data['api_key']}), {'error': 'oops <redacted>'})


if __name__ == '__main__':
    unittest.main(verbosity=2)
