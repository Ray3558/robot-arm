import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from bridge import normalize, read_codex

class QuotaTests(unittest.TestCase):
    def test_quota_and_null_windows(self):
        q = normalize({'rateLimits': {'primary': {'usedPercent': 25, 'windowDurationMins': 300, 'resetsAt': 123}, 'secondary': None}})
        self.assertEqual(q['primary']['remaining'], 75)
        self.assertIsNone(q['secondary'])
    def test_no_fake_quota(self):
        for bad in [{}, {'rateLimitsByLimitId': {'other': {}}},
                    {'rateLimits': {'primary': {'usedPercent': 101, 'windowDurationMins': 1}}}]:
            with self.assertRaises(ValueError): normalize(bad)
    def test_rpc_handshake(self):
        with tempfile.TemporaryDirectory() as d:
            fake = Path(d) / 'codex'
            fake.write_text('''#!/usr/bin/env python3
import sys, json
assert sys.argv[1:] == ['app-server']
a = json.loads(input()); assert a['method'] == 'initialize'
print(json.dumps({'id': a['id'], 'result': {}}), flush=True)
assert json.loads(input())['method'] == 'initialized'
b = json.loads(input()); assert b['method'] == 'account/rateLimits/read'
print(json.dumps({'id': b['id'], 'result': {'rateLimits': {'primary': {'usedPercent': 12, 'windowDurationMins': 300}}}}), flush=True)
for line in sys.stdin: pass
''')
            fake.chmod(0o700)
            self.assertEqual(read_codex(str(fake))['primary']['remaining'], 88)
    def test_http_demo_auth_and_registration(self):
        import socket
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]
        with tempfile.TemporaryDirectory() as d:
            import shutil
            target = Path(d) / 'bridge.py'
            shutil.copyfile(Path(__file__).with_name('bridge.py'), target)
            proc = subprocess.Popen(['python3', str(target), '--demo', '--port', str(port)], stdout=subprocess.DEVNULL)
            try:
                for _ in range(50):
                    if (Path(d) / '.bridge-token').exists():
                        try:
                            with socket.create_connection(('127.0.0.1', port), timeout=.1): break
                        except OSError: pass
                    time.sleep(.05)
                token_path = Path(d) / '.bridge-token'
                self.assertEqual(token_path.stat().st_mode & 0o777, 0o600)
                token = token_path.read_text()
                url = f'http://127.0.0.1:{port}'
                with self.assertRaises(HTTPError) as error: urlopen(url + '/quota')
                self.assertEqual(error.exception.code, 401)
                headers = {'Authorization': 'Bearer ' + token}
                q = json.load(urlopen(Request(url + '/quota', headers=headers)))
                self.assertTrue(q['demo']); self.assertEqual(q['primary']['remaining'], 75)
                result = json.load(urlopen(Request(url + '/register', data=json.dumps({'token': 'ab' * 32}).encode(), headers=headers)))
                self.assertFalse(result['pushEnabled'])
            finally:
                proc.terminate(); proc.wait(timeout=3)

if __name__ == '__main__': unittest.main()
