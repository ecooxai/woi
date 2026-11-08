"""Transport-boundary timing checks with injected clocks; no provider calls."""
from __future__ import annotations

import asyncio
import http.client
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib import error, request

import adapters as a
import server
from test_speed_tiers import png, trial


class Clock:
    def __init__(self): self.value = 100.0
    def __call__(self): return self.value
    def at(self, ms): self.value = 100.0 + ms / 1000
    def advance(self, ms): self.value += ms / 1000


class Socket:
    """The real HTTPConnection send loop uses this local sendall implementation."""
    def __init__(self, clock, fail_body=False):
        self.clock, self.fail_body, self.sent = clock, fail_body, []
    def sendall(self, data):
        is_body = len(self.sent) > 0
        self.clock.advance(200 if is_body else 100)
        if is_body and self.fail_body:
            raise OSError('injected body send failure')
        self.sent.append(bytes(data))
    def close(self): pass


def send_request(req, clock, fail_body=False):
    sock = Socket(clock, fail_body)
    conn = http.client.HTTPConnection('example.invalid')
    conn.sock = sock
    # Exercise the actual Python stdlib headers/body/sendall path, without a socket.
    conn.request(req.method, '/v1/responses', body=req.data, headers=dict(req.header_items()))
    return sock


class Stream:
    def __init__(self, clock, events): self.clock, self.events = clock, events
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def __iter__(self):
        for at, event in self.events:
            self.clock.at(at)
            yield b'data: ' + json.dumps(event).encode() + b'\n'


def completed(kind='response.completed', status='completed'):
    return {'type':kind, 'response':{'model':'test-model', 'status':status, 'service_tier':'default',
            'output':[{'type':'function_call','name':'screen_action','arguments':'{"action":"click","x":8,"y":8}'}]}}


class TimingTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.timing = a.ProviderTiming(self.clock)
        self.creds = a.Credentials('api', 'synthetic-key-for-timing-tests')
        self.catalog = {'models':[{'id':'test-model','transport':'responses','available':True}], 'auth':{'mode':'api'}}
        self.sent = []

    def open_stream(self, events, fail_body=False):
        def open_request(req, **kwargs):
            sock = send_request(req, self.clock, fail_body)
            self.sent.append((req, sock))
            return Stream(self.clock, events)
        return patch.object(a.request, 'urlopen', side_effect=open_request)

    def api_call(self):
        with patch.object(a, 'discover_models', return_value=self.catalog), \
             patch.object(a, 'load_credentials', return_value=self.creds), \
             patch.object(a, 'ProviderTiming', return_value=self.timing), \
             patch.object(a, '_last_status', {}):
            return a.run_trial(trial())

    def test_real_http_send_loop_preserves_bytes_length_and_single_use(self):
        value = a.validate_trial(trial(speed_tier='fast'))
        expected = json.dumps(a.responses_payload(value, {})).encode()
        with self.open_stream([(500,completed())]):
            result = a.responses_trial(value, {}, self.creds, timing=self.timing)
        req, sock = self.sent[0]
        self.assertEqual(sock.sent[1:], [expected])
        self.assertIn(b'content-length: '+str(len(expected)).encode(), sock.sent[0].lower())
        self.assertNotIn(b'transfer-encoding:', sock.sent[0].lower())
        self.assertEqual(result['request_payload_bytes'],len(expected))
        self.assertEqual(result['timing']['upload_complete_ms'],300)
        self.assertEqual(result['timing']['upload_duration_ms'],200)
        with self.assertRaises(a.LabError) as raised:
            list(req.data)
        self.assertEqual(raised.exception.code,'request_body_replay')

    def test_empty_body_does_not_invent_upload_completion(self):
        self.timing.start(0,'test','test')
        body=a.TimedUploadBody(b'',self.timing)
        req=request.Request('https://example.invalid',data=body,headers={'Content-Length':'0'},method='POST')
        sock=send_request(req,self.clock)
        self.assertEqual(len(sock.sent),1)
        self.assertIsNone(self.timing.snapshot()['upload_complete_ms'])
        self.assertIsNone(self.timing.snapshot()['upload_duration_ms'])

    def test_setup_reasoning_empty_deltas_ignored_and_completed_tier_wins(self):
        events=[(400,{'type':'response.created','response':{'service_tier':'priority'}}),
                (600,{'type':'response.in_progress'}),
                (700,{'type':'response.reasoning_text.delta','delta':'internal'}),
                (800,{'type':'response.function_call_arguments.delta','delta':''}),
                (900,{'type':'response.output_text.delta','delta':'  '}),
                (1200,{'type':'response.function_call_arguments.delta','delta':'{"action"'}),
                (1800,completed())]
        with self.open_stream(events):
            result=a.responses_trial(trial(),{},self.creds,timing=self.timing)
        t=result['timing']
        self.assertEqual((t['first_token_ms'],t['first_output_ms'],t['finish_ms']),(1200,1200,1800))
        self.assertEqual(t['first_output_source'],'stream_delta')
        self.assertEqual(t['status'],'completed')
        self.assertEqual(result['actual_service_tier'],'default')

    def test_text_delta_is_first_output_and_final_only_keeps_token_unknown(self):
        for events, token, source in [
            ([(700,{'type':'response.output_text.delta','delta':'Click'}),(1800,completed())],700,'stream_delta'),
            ([(700,{'type':'response.created'}),(1800,completed())],None,'final_only')]:
            with self.subTest(source=source):
                self.clock=Clock();self.timing=a.ProviderTiming(self.clock)
                with self.open_stream(events):
                    result=a.responses_trial(trial(),{},self.creds,timing=self.timing)
                t=result['timing']
                self.assertEqual(t['first_token_ms'],token)
                self.assertEqual(t['first_output_ms'],token if token is not None else 1800)
                self.assertEqual(t['first_output_source'],source)

    def test_stream_error_preserves_partial_timing_in_api_result(self):
        with self.open_stream([(800,{'type':'response.function_call_arguments.delta','delta':'{' }),
                               (1400,{'type':'error','message':'injected provider failure'})]):
            result=self.api_call()
        t=result['timing']
        self.assertEqual(result['error_code'],'provider_error')
        self.assertEqual((t['upload_complete_ms'],t['first_token_ms'],t['finish_ms']),(300,800,1400))
        self.assertEqual(t['status'],'error')
        self.assertEqual(result['request_image_bytes'],len(png()))
        self.assertGreater(result['request_payload_bytes'],result['request_image_bytes'])
        self.assertNotIn(self.creds.token,json.dumps(result))

    def test_http_error_keeps_uploaded_bytes_but_no_first_token(self):
        def reject(req,**kwargs):
            send_request(req,self.clock)
            self.clock.at(950)
            raise error.HTTPError(req.full_url,400,'Bad Request',{},io.BytesIO(b'{"error":{"message":"Rejected request"}}'))
        with patch.object(a.request,'urlopen',side_effect=reject):
            result=self.api_call()
        t=result['timing']
        self.assertEqual(t['status'],'error')
        self.assertEqual((t['upload_complete_ms'],t['finish_ms']),(300,950))
        self.assertIsNone(t['first_token_ms'])
        self.assertIsNone(t['first_output_ms'])

    def test_failed_body_send_keeps_upload_unknown(self):
        with self.open_stream([],fail_body=True):
            result=self.api_call()
        self.assertEqual(result['error_code'],'transport_error')
        self.assertEqual(result['timing']['status'],'error')
        self.assertEqual(result['timing']['finish_ms'],300)
        for field in ('upload_complete_ms','upload_duration_ms','first_token_ms','first_output_ms'):
            self.assertIsNone(result['timing'][field])

    def test_unsupported_transport_never_starts_timing(self):
        self.catalog['models'][0]['transport']='realtime'
        with patch.object(a,'discover_models',return_value=self.catalog), \
             patch.object(a,'load_credentials',return_value=self.creds), \
             patch.object(a,'realtime_trial') as provider, patch.object(a,'_last_status',{}):
            result=a.run_trial(trial(speed_tier='flex'))
        provider.assert_not_called()
        self.assertEqual(result['error_code'],'tier_unsupported_transport')
        self.assertEqual(result['timing']['status'],'not_started')
        self.assertIsNone(result['request_payload_bytes'])
        for field in ('upload_complete_ms','upload_duration_ms','first_token_ms','first_output_ms','finish_ms'):
            self.assertIsNone(result['timing'][field])

    def test_local_validation_error_returns_not_started_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            app=server.make_server(port=0,output=Path(directory),runner=lambda _:self.fail('Provider should not run'))
            thread=threading.Thread(target=app.serve_forever,daemon=True);thread.start()
            try:
                req=request.Request(f'http://127.0.0.1:{app.server_address[1]}/api/trial',b'{"model":"test-model"}',{'Content-Type':'application/json'},method='POST')
                with self.assertRaises(error.HTTPError) as raised: request.urlopen(req)
                result=json.load(raised.exception)
                self.assertEqual(result['timing']['status'],'not_started')
                self.assertIsNone(result['request_image_bytes'])
                self.assertIsNone(result['timing']['finish_ms'])
            finally:
                app.shutdown();app.server_close();thread.join()

    def test_local_log_error_preserves_measured_provider_timing(self):
        measured={'request_image_bytes':len(png()),'request_payload_bytes':1900,
                  'timing':{'origin':'provider_request_start','upload_complete_ms':100,'first_token_ms':250,
                            'first_output_ms':250,'first_output_source':'stream_delta','finish_ms':400,'status':'completed'}}
        with tempfile.TemporaryDirectory() as directory:
            app=server.make_server(port=0,output=Path(directory),runner=lambda _:measured)
            thread=threading.Thread(target=app.serve_forever,daemon=True);thread.start()
            try:
                req=request.Request(f'http://127.0.0.1:{app.server_address[1]}/api/trial',json.dumps(trial()).encode(),{'Content-Type':'application/json'},method='POST')
                with patch.object(app.evidence,'trial',side_effect=OSError('injected evidence-write failure')):
                    with self.assertRaises(error.HTTPError) as raised: request.urlopen(req)
                result=json.load(raised.exception)
                self.assertEqual(result['timing'],measured['timing'])
                self.assertEqual(result['request_payload_bytes'],1900)
                self.assertEqual(result['request_image_bytes'],len(png()))
            finally:
                app.shutdown();app.server_close();thread.join()

    def realtime(self, *, final_only=False, fail_send=False, fail_response=False):
        clock=self.clock
        sent=[]
        class WebSocket:
            def __init__(self):
                self.events=[(300,{'type':'session.created','session':{'model':'test-model'}}),
                             (500,{'type':'session.updated'}),(850,{'type':'response.created'})]
                if not final_only:
                    self.events.append((1200,{'type':'response.function_call_arguments.delta','delta':'{"action"'}))
                self.events.append((1800,completed('response.done','failed' if fail_response else 'completed')))
            async def __aenter__(self): clock.advance(100);return self
            async def __aexit__(self,*args): pass
            async def send(self,payload):
                kind=json.loads(payload)['type']
                clock.advance(200 if kind=='response.create' else 50)
                if kind=='response.create' and fail_send: raise OSError('injected WebSocket send failure')
                sent.append(payload)
            async def recv(self):
                at,event=self.events.pop(0);clock.at(at);return json.dumps(event)
        with patch('websockets.connect',side_effect=lambda *args,**kwargs:WebSocket()):
            result=asyncio.run(a.realtime_trial(trial(),{},self.creds,timing=self.timing))
        return result,sent

    def test_realtime_connection_session_setup_and_body_send_are_distinct(self):
        result,sent=self.realtime()
        t=result['timing']
        self.assertEqual((t['upload_complete_ms'],t['upload_duration_ms']),(700,200))
        self.assertEqual((t['first_token_ms'],t['first_output_ms'],t['finish_ms']),(1200,1200,1800))
        self.assertEqual(result['request_payload_bytes'],sum(len(value.encode()) for value in sent))
        self.assertEqual([json.loads(v)['type'] for v in sent],['session.update','response.create'])
        self.assertIn('session.update and response.create',t['note'])
        self.assertEqual(t['upload_measurement'],'websocket.send_returned')

    def test_realtime_final_only_is_not_a_measured_token(self):
        result,_=self.realtime(final_only=True)
        self.assertIsNone(result['timing']['first_token_ms'])
        self.assertEqual(result['timing']['first_output_ms'],1800)
        self.assertEqual(result['timing']['first_output_source'],'final_only')

    def test_realtime_failure_preserves_observed_stages(self):
        for fail_send,fail_response in ((True,False),(False,True)):
            with self.subTest(fail_send=fail_send):
                self.clock=Clock();self.timing=a.ProviderTiming(self.clock)
                with self.assertRaises((OSError,a.LabError)):
                    self.realtime(fail_send=fail_send,fail_response=fail_response)
                t=self.timing.snapshot()
                self.assertEqual(t['status'],'error')
                self.assertEqual(t['finish_ms'],700 if fail_send else 1800)
                self.assertEqual(t['upload_complete_ms'],None if fail_send else 700)
                self.assertEqual(t['first_token_ms'],None if fail_send else 1200)


if __name__=='__main__': unittest.main(verbosity=2)
