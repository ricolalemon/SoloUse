#!/usr/bin/env python3
import importlib.util, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('check',ROOT/'Scripts/check-release.py');check=importlib.util.module_from_spec(spec);spec.loader.exec_module(check)
class PublicationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.files=list(check.publication_files())
    def rejects(self,name,data):
        errors=check.audit(self.files+[(name,data)])
        self.assertTrue(any(p==name for p,_ in errors),errors)
    def test_baseline(self):self.assertEqual(check.audit(self.files),[])
    def test_credential_file(self):self.rejects('App/auth.json',b'{}')
    def test_key_marker(self):self.rejects('Docs/bad.md',b'-----BEGIN '+b'PRIVATE KEY-----')
    def test_api_token(self):self.rejects('App/bad.swift',('sk-'+('x'*36)).encode())
    def test_embedded_screenshot(self):self.rejects('Docs/bad.json',('data:image/png;base64,'+('A'*160)).encode())
    def test_stored_token(self):self.rejects('Docs/bad.json',__import__('json').dumps({'refresh_token':'x'*40}).encode())
    def test_unknown_root_file(self):self.rejects('unreviewed.txt',b'anything')
    def test_path_escape(self):self.rejects('../outside.md',b'anything')
    def test_generated_project(self):self.rejects('App/Local.xcodeproj/project.pbxproj',b'anything')
    def test_missing_notice(self):
        inv=next(x for x in self.files if x[0]=='Licenses/cargo-inventory.json')
        name=__import__('json').loads(inv[1])['packages'][0]['notices'][0]['path']
        self.assertTrue(any(p==name for p,_ in check.audit([x for x in self.files if x[0]!=name])))
if __name__=='__main__':unittest.main()
