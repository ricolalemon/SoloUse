#!/usr/bin/env python3
"""Create an audited source-only archive; never publish it remotely."""
import argparse, importlib.util, tempfile, zipfile, os
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('release_check',ROOT/'Scripts/check-release.py');check=importlib.util.module_from_spec(spec);spec.loader.exec_module(check)
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',required=True,type=Path);args=p.parse_args()
files=list(check.publication_files());errors=check.audit(files)
if errors:raise SystemExit('Release audit failed: '+repr(errors))
target=args.output.resolve();target.parent.mkdir(parents=True,exist_ok=True)
if target.exists():raise SystemExit('Output exists; use a new path rather than replace a reviewed archive.')
fd,temporary=tempfile.mkstemp(prefix='solouse-source-',suffix='.zip',dir=target.parent);os.close(fd)
try:
 with zipfile.ZipFile(temporary,'w',zipfile.ZIP_DEFLATED) as z:
  for name,data in files:
   info=zipfile.ZipInfo('SoloUse/'+name,date_time=(2026,1,1,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED
   info.external_attr=(0o100755 if name.endswith('.sh') else 0o100644)<<16
   z.writestr(info,data)
 with zipfile.ZipFile(temporary) as z:
  if z.testzip() is not None:raise ValueError('ZIP integrity check failed')
 os.replace(temporary,target)
finally:
 Path(temporary).unlink(missing_ok=True)
print('Created source-only archive:',target)
