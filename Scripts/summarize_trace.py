#!/usr/bin/env python3
"""Emit aggregate numerical diagnostics only, never messages, arguments, screenshots or identifiers."""
import argparse, json
from pathlib import Path

def summarize(lines):
    events=0;invalid=0;model_requests=0;completed_requests=0;errors=0;images=0
    elapsed=[];request_bytes=[];input_tokens=[];checkpoint_ms=[]
    def number(value):
        return isinstance(value,(int,float)) and not isinstance(value,bool) and 0<=value<10**12
    for line in lines:
        try:r=json.loads(line)
        except (ValueError,TypeError):invalid+=1;continue
        if not isinstance(r,dict):invalid+=1;continue
        events+=1;kind=r.get('kind');f=r.get('fields',r)
        if not isinstance(f,dict):continue
        if kind=='model_request_metrics':
            model_requests+=1;completed_requests+=f.get('completed') is True
            if number(f.get('elapsedMS')):elapsed.append(f['elapsedMS'])
            if number(f.get('requestBytes')):request_bytes.append(f['requestBytes'])
            usage=f.get('usage',{})
            if isinstance(usage,dict) and number(usage.get('inputTokens')):input_tokens.append(usage['inputTokens'])
        if kind in ['error','command_failed','native_command_failed','native_worker_error']:errors+=1
        if kind=='observation':images+=1
        if kind=='recovery_checkpoint_saved' and number(f.get('elapsed_ms')):checkpoint_ms.append(f['elapsed_ms'])
    return {'events':events,'invalid_lines':invalid,'model_requests':model_requests,
            'completed_model_requests':completed_requests,'reported_error_events':errors,'observations':images,
            'model_elapsed_ms_sum':round(sum(elapsed),3),'max_request_bytes':max(request_bytes,default=0),
            'max_input_tokens':max(input_tokens,default=0),'checkpoint_samples':len(checkpoint_ms),
            'checkpoint_max_ms':round(max(checkpoint_ms,default=0),3),
            'scope':'Aggregate recorded metadata only. Does not establish task success or absence of sensitive material in the input log.'}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('trace',type=Path);args=p.parse_args()
    with args.trace.open(encoding='utf-8') as f:report=summarize(f)
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
