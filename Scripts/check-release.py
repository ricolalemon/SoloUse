#!/usr/bin/env python3
"""Fail closed on disallowed public files, common secrets, broken docs and missing license evidence."""
import argparse, hashlib, json, re, sys, zipfile, subprocess
from pathlib import Path, PurePosixPath
ROOT = Path(__file__).resolve().parents[1]
TOP_DIRS = {'App','Native','Lab','TreeRunner','Scripts','Licenses','Docs','Design','.github'}
TOP_FILES = {'README.md','README.zh-CN.md','LICENSE','NOTICE','THIRD_PARTY_NOTICES.md','CONTRIBUTING.md','SECURITY.md','CHANGELOG.md','project.yml','.gitignore','.gitattributes','Config.defaults.xcconfig','Config.local.xcconfig.example'}
IGNORED_PARTS = {'target','Build','.build','__pycache__','.git','xcuserdata','.DS_Store'}
FORBIDDEN_SUFFIX = {'.ipa','.p12','.p8','.cer','.crt','.der','.mobileprovision','.provisionprofile','.a','.dylib','.so','.o','.log','.jsonl','.png','.jpg','.jpeg','.mov','.mp4','.key','.pem'}
FORBIDDEN_NAMES = {'auth.json','pairing.plist','pairingFile.plist','Config.local.xcconfig','media-session-owner','conversation.json','recovery.json','latest-task.json','demo-launch-status.json'}
PATTERNS = {
    'private-key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'),
    'api-secret': re.compile(r'\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[A-Z0-9]{16})\b'),
    'embedded-image': re.compile(r'data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=]{128,}'),
    'stored-token': re.compile(r'''["'](?:access_token|refresh_token|accountTag)["']\s*:\s*["'][A-Za-z0-9._-]{32,}["']'''),
    'jwt': re.compile(r'\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{16,}\b'),
    'home-path': re.compile(r'/(?:Users|home)/[A-Za-z0-9._-]+/'),
    'apple-device-id': re.compile(r'\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b'),
    'signing-team': re.compile(r'DEVELOPMENT_TEAM\s*[=:]\s*["\']?[A-Z0-9]{10}\b'),
}
# Only exact known synthetic redaction-test values are allowed, not whole files.
FIXTURES = {'sk-fixture-secret-token-for-test'}

def publication_files(root=ROOT):
    for p in sorted(root.rglob('*')):
        rel=p.relative_to(root);parts=rel.parts
        if any(x in IGNORED_PARTS or x.endswith(('.xcodeproj','.xcworkspace','.app','.dSYM','.xcarchive')) for x in parts):continue
        if parts[0] not in TOP_DIRS and str(rel) not in TOP_FILES:continue
        if p.is_symlink():raise ValueError('Symlink not publishable: '+str(rel))
        if p.is_file():yield str(rel),p.read_bytes()

def audit(files):
    errors=[];paths={name for name,_ in files}
    exceptions=json.loads(dict(files).get('Scripts/release-scan-exceptions.json',b'[]'))
    for name,data in files:
        p=PurePosixPath(name)
        if p.is_absolute() or '..' in p.parts or '\\' in name:errors.append((name,'unsafe archive path'));continue
        if p.parts[0] not in TOP_DIRS and name not in TOP_FILES:
            errors.append((name,'outside publication allowlist'));continue
        if any(x in IGNORED_PARTS or x.endswith(('.xcodeproj','.xcworkspace','.app','.dSYM','.xcarchive')) for x in p.parts):
            errors.append((name,'generated/private directory'));continue
        if p.suffix.lower() in FORBIDDEN_SUFFIX or p.name in FORBIDDEN_NAMES or '.git' in p.parts:
            errors.append((name,'private or generated file type'));continue
        try:text=data.decode('utf-8')
        except UnicodeDecodeError:errors.append((name,'unexpected binary/non-UTF8 file'));continue
        for label,pattern in PATTERNS.items():
            for m in pattern.finditer(text):
                if any(x['path']==name and x['rule']==label and x['sha256']==hashlib.sha256(m.group().encode()).hexdigest() for x in exceptions):continue
                if m.group() in FIXTURES or (label=='apple-device-id' and set(m.group()) <= {'0','-'}):continue
                errors.append((name, f'{label} at line {text.count(chr(10),0,m.start())+1} [value redacted]'))
        if p.suffix=='.md' and not name.startswith(('Native/vendor/','Licenses/Cargo/')):
            for dest in re.findall(r'\]\(([^)]+)\)',text):
                dest=dest.strip('<>').split('#',1)[0]
                if not dest or re.match(r'[a-zA-Z]+:',dest):continue
                target=(ROOT/p.parent/dest).resolve()
                try:rel=str(target.relative_to(ROOT))
                except ValueError:errors.append((name,'documentation link escapes repository'));continue
                if rel not in paths and not any(x.startswith(rel.rstrip('/')+'/') for x in paths):errors.append((name,'missing local link: '+dest))
    required={'README.md','README.zh-CN.md','LICENSE','NOTICE','THIRD_PARTY_NOTICES.md','Licenses/cargo-inventory.json','Docs/INSTALL.md','Docs/INSTALL.zh-CN.md'}
    for name in sorted(required-paths):errors.append((name,'required publication file missing'))
    mapping=dict(files)
    if 'Licenses/cargo-inventory.json' in mapping:
        inv=json.loads(mapping['Licenses/cargo-inventory.json'])
        for pkg in inv['packages']:
            if not pkg.get('notices'):errors.append((pkg['name'],'no dependency license evidence'))
            for f in pkg['notices']:
                data=mapping.get(f['path'])
                if data is None or hashlib.sha256(data).hexdigest()!=f['sha256']:errors.append((f['path'],'license evidence missing or changed'))
    return errors

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--archive',type=Path);p.add_argument('--report',type=Path);args=p.parse_args()
    tracked_extra=[]
    if args.archive:
        with zipfile.ZipFile(args.archive) as z:
            files=[]
            for i in z.infolist():
                if i.is_dir():continue
                if (i.external_attr >> 16) & 0o170000 == 0o120000:raise ValueError('Archive contains a symlink')
                name=i.filename
                if name.startswith('SoloUse/'):name=name[len('SoloUse/'):]
                files.append((name,z.read(i)))
    else:
        files=list(publication_files())
        if (ROOT/'.git').exists():
            tracked=subprocess.check_output(['git','-C',str(ROOT),'ls-files','-z']).decode().split('\0')
            known={n for n,_ in files}
            for name in tracked:
                if name and name not in known:tracked_extra.append((name,'tracked file outside reviewed publication manifest; contents not read'))
    errors=audit(files)+tracked_extra
    result={'files':len(files),'bytes':sum(len(d) for _,d in files),'passed':not errors,'findings':[{'path':n,'reason':m} for n,m in errors],
            'scope':'Common secret/identifier patterns, publication-file policy, local documentation links and retained license hashes. Not proof that arbitrary text is non-sensitive; manual review is also required.'}
    if args.report:args.report.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,ensure_ascii=False,indent=2));return bool(errors)
if __name__=='__main__':sys.exit(main())
