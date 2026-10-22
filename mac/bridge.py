#!/usr/bin/env python3
"""Local Codex quota bridge. No OpenAI credentials leave this computer."""
import argparse
import hmac
import json
import math
import os
import queue
import secrets
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def normalize(result):
    buckets = result.get('rateLimitsByLimitId')
    if buckets:
        if 'codex' not in buckets:
            raise ValueError('No codex bucket; refusing to display another quota')
        bucket = buckets['codex']
    else:
        bucket = result.get('rateLimits') or {}
        if bucket.get('limitId') not in (None, 'codex'):
            raise ValueError('Unexpected quota bucket')
    def window(w):
        if not w:
            return None
        used = float(w['usedPercent'])
        if not math.isfinite(used) or not 0 <= used <= 100:
            raise ValueError('Invalid usedPercent')
        return {'remaining': int(100 - used), 'minutes': int(w['windowDurationMins']),
                'resetAt': w.get('resetsAt')}
    primary = window(bucket.get('primary'))
    if primary is None:
        raise ValueError('Primary quota unavailable; sign in with ChatGPT')
    return {'primary': primary, 'secondary': window(bucket.get('secondary')),
            'updatedAt': int(time.time())}


def read_codex(binary):
    proc = subprocess.Popen([binary, 'app-server'], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    lines = queue.Queue()
    def drain():
        for line in proc.stdout:
            lines.put(line)
        lines.put(None)
    threading.Thread(target=drain, daemon=True).start()
    def send(obj):
        proc.stdin.write(json.dumps(obj) + '\n')
        proc.stdin.flush()
    def response(request_id):
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            line = lines.get(timeout=max(.01, deadline - time.monotonic()))
            if line is None:
                raise RuntimeError('Codex app-server exited')
            msg = json.loads(line)
            if msg.get('id') == request_id:
                if 'error' in msg:
                    raise RuntimeError('Codex request failed: ' + str(msg['error'].get('code')))
                return msg['result']
        raise TimeoutError('Codex request timed out')
    try:
        send({'id': 1, 'method': 'initialize', 'params': {'clientInfo': {
            'name': 'codex_island', 'title': 'Codex Island', 'version': '0.1.0'}}})
        response(1)
        send({'method': 'initialized', 'params': {}})
        send({'id': 2, 'method': 'account/rateLimits/read'})
        return normalize(response(2))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        proc.stdin.close()
        proc.stdout.close()


def push(token, snapshot):
    import httpx
    import jwt
    now = int(time.time())
    provider = jwt.encode({'iss': os.environ['APNS_TEAM_ID'], 'iat': now},
        Path(os.environ['APNS_KEY_PATH']).read_text(), algorithm='ES256',
        headers={'kid': os.environ['APNS_KEY_ID']})
    p, s = snapshot['primary'], snapshot['secondary']
    state = {'remaining': p['remaining'], 'secondaryRemaining': s['remaining'] if s else None,
             'resetAt': p['resetAt'], 'updatedAt': snapshot['updatedAt']}
    host = 'api.sandbox.push.apple.com' if os.getenv('APNS_ENV', 'sandbox') == 'sandbox' else 'api.push.apple.com'
    with httpx.Client(http2=True, timeout=15) as client:
        r = client.post(f'https://{host}/3/device/{token}', headers={
            'authorization': 'bearer ' + provider, 'apns-push-type': 'liveactivity',
            'apns-topic': os.environ['APNS_BUNDLE_ID'] + '.push-type.liveactivity',
            'apns-priority': '5', 'apns-expiration': str(now + 300)}, json={'aps': {
                'timestamp': now, 'event': 'update', 'content-state': state, 'stale-date': now + 180}})
    return r.status_code


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--codex', default='codex')
    parser.add_argument('--demo', action='store_true')
    args = parser.parse_args()
    secret_path = Path(__file__).with_name('.bridge-token')
    if not secret_path.exists():
        fd = os.open(secret_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write(secrets.token_urlsafe(32))
    secret = secret_path.read_text().strip()
    lock = threading.Lock()
    data = {'snapshot': None, 'error': 'Starting', 'tokens': {}}
    push_enabled = all(os.getenv(k) for k in ['APNS_TEAM_ID', 'APNS_KEY_ID', 'APNS_KEY_PATH', 'APNS_BUNDLE_ID'])
    def worker():
        while True:
            try:
                snap = ({'primary': {'remaining': 75, 'minutes': 300, 'resetAt': int(time.time()) + 3600},
                         'secondary': None, 'updatedAt': int(time.time())} if args.demo else read_codex(args.codex))
                with lock:
                    data.update(snapshot=snap, error=None)
                    tokens = list(data['tokens'].items())
                if push_enabled:
                    for token, registered in tokens:
                        if time.time() - registered > 8 * 3600:
                            with lock:
                                data['tokens'].pop(token, None)
                            continue
                        try:
                            status = push(token, snap)
                            if status in (400, 410):
                                with lock:
                                    data['tokens'].pop(token, None)
                            if status != 200:
                                print('APNs HTTP', status, flush=True)
                        except Exception as e:
                            print('APNs failed:', type(e).__name__, flush=True)
            except Exception as e:
                with lock:
                    data['error'] = type(e).__name__ + ': quota unavailable; check codex login / version'
            time.sleep(60)
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # Never log credentials or push tokens.
        def reply(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def authorized(self):
            return hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + secret)
        def do_GET(self):
            if not self.authorized():
                return self.reply(401, {'error': 'Unauthorized'})
            if self.path != '/quota':
                return self.reply(404, {'error': 'Not found'})
            with lock:
                snap, error = data['snapshot'], data['error']
            if error or not snap or time.time() - snap['updatedAt'] > 180:
                return self.reply(503, {'error': error or 'Stale quota'})
            self.reply(200, {**snap, 'demo': args.demo, 'pushEnabled': push_enabled})
        def do_POST(self):
            if not self.authorized():
                return self.reply(401, {'error': 'Unauthorized'})
            if self.path != '/register':
                return self.reply(404, {'error': 'Not found'})
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 2048:
                    raise ValueError()
                token = json.loads(self.rfile.read(length))['token']
                if not isinstance(token, str) or not 32 <= len(token) <= 1024 or any(c not in '0123456789abcdef' for c in token):
                    raise ValueError()
                with lock:
                    if len(data['tokens']) >= 20 and token not in data['tokens']:
                        return self.reply(429, {'error': 'Too many activities'})
                    data['tokens'][token] = time.time()
                self.reply(200, {'pushEnabled': push_enabled})
            except (ValueError, KeyError, TypeError):
                self.reply(400, {'error': 'Invalid token'})
    threading.Thread(target=worker, daemon=True).start()
    print(f'Listening on {args.host}:{args.port}; pairing token is in {secret_path}', flush=True)
    print('DEMO DATA' if args.demo else 'Reading real Codex limits', flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()

if __name__ == '__main__':
    main()
