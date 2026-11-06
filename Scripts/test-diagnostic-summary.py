#!/usr/bin/env python3
import importlib.util,json,unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('summary',Path(__file__).with_name('summarize_trace.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class SummaryTests(unittest.TestCase):
    def test_metadata_only(self):
        secret='PRIVATE_FIXTURE_'+'DO_NOT_SHARE'
        rows=[{'kind':'error','fields':{'message':secret,'access_token':secret,'device_id':secret}},
              {'kind':'tool_started','fields':{'arguments':{'text':secret},'tool_call_id':secret}},
              {'kind':'model_request_metrics','fields':{'completed':True,'elapsedMS':25,'requestBytes':1200,'usage':{'inputTokens':42},'requestID':secret}},
              {'kind':'recovery_checkpoint_saved','fields':{'elapsed_ms':3,'task_id':secret}}]
        result=m.summarize([json.dumps(x) for x in rows]);encoded=json.dumps(result)
        self.assertNotIn(secret,encoded);self.assertEqual(result['max_input_tokens'],42)
        self.assertEqual(result['reported_error_events'],1)
    def test_malformed_input(self):
        result=m.summarize(['bad','[]',json.dumps({'kind':'model_request_metrics','fields':{'usage':None,'elapsedMS':float('inf')}})])
        self.assertEqual(result['invalid_lines'],2);self.assertEqual(result['model_elapsed_ms_sum'],0)
if __name__=='__main__':unittest.main()
