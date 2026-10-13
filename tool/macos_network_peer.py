"""Run the local macOS network_check app against a loopback peer.
Usage: python3 tool/macos_network_peer.py /path/to/app/executable
"""
from email.parser import BytesParser
from email.policy import default
import base64
import http.server
import json
import os
import subprocess
import sys
import threading


class Peer(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        if self.path == '/process.Process/Start':
            self.server.calls.append('command')
            data = self.rfile.read(int(self.headers['Content-Length']))
            request = json.loads(data[5:])
            valid = (self.headers.get('X-Access-Token') == 'local-token'
                     and self.headers.get('X-API-Key') is None
                     and request['process']['args'] == ['-l', '-c', 'printf local-command'])
            def frame(value, flag=0):
                encoded = json.dumps(value).encode()
                return bytes([flag]) + len(encoded).to_bytes(4, 'big') + encoded
            first = frame({'event': {'start': {'pid': 42}}}) + frame({'event': {
                'data': {'stdout': base64.b64encode(b'local-command').decode()}}})
            tail = frame({'event': {'end': {'exitCode': 0}}}) + frame({}, 2)
            self.send_response(200 if valid else 400)
            self.send_header('Content-Type', 'application/connect+json')
            self.send_header('Content-Length', str(len(first) + len(tail)))
            self.end_headers()
            self.wfile.write(first)
            self.wfile.flush()
            self.server.command_ok = valid and self.server.command_ack.wait(5)
            self.wfile.write(tail)
            return
        if self.path.startswith('/files?'):
            self.server.calls.append('file_write')
            data = self.rfile.read(int(self.headers['Content-Length']))
            message = BytesParser(policy=default).parsebytes(
                ('Content-Type: ' + self.headers['Content-Type'] + '\r\n\r\n').encode() + data)
            parts = list(message.iter_parts())
            valid = (self.headers.get('X-Access-Token') == 'local-token'
                     and self.headers.get('X-API-Key') is None and len(parts) == 1
                     and parts[0].get_filename() == '/local-data'
                     and parts[0].get_payload(decode=True) == bytes([0, 128, 255, 1, 2, 3]))
            self.server.files_ok = valid
            body = json.dumps([{'path': '/local-data', 'name': 'local-data', 'size': 6}]).encode()
            self.send_response(200 if valid else 400)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.server.calls.append('create')
        valid = self.path == '/v2/sandboxes' and self.headers.get('X-API-Key') == 'local-macos-test-key'
        data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        valid = valid and data.get('timeout') == 60
        body = json.dumps({'sandboxID': 'macos-local', 'envdVersion': '0.6.4',
                           'envdAccessToken': 'local-token', 'domain': 'e2b.app'}).encode()
        self.send_response(201 if valid else 400)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/command-output-ack':
            self.server.calls.append('command_ack')
            self.server.command_ack.set()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', '2')
            self.end_headers()
            self.wfile.write(b'{}')
            return
        self.server.calls.append('file_read')
        valid = (self.path.startswith('/files?') and 'path=%2Flocal-data' in self.path
                 and self.headers.get('X-Access-Token') == 'local-token'
                 and self.headers.get('X-API-Key') is None)
        self.send_response(200 if valid else 400)
        body = bytes([0, 128, 255, 1, 2, 3])
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_DELETE(self):
        self.server.calls.append('kill')
        valid = self.path == '/sandboxes/macos-local' and self.headers.get('X-API-Key') == 'local-macos-test-key'
        self.send_response(204 if valid else 400)
        self.end_headers()


with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Peer) as server:
    server.calls = []
    server.files_ok = False
    server.command_ok = False
    server.command_ack = threading.Event()
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    env = dict(os.environ, E2B_LOCAL_TEST_ORIGIN=f'http://127.0.0.1:{server.server_port}')
    try:
        result = subprocess.run([sys.argv[1]], env=env, timeout=30)
        if result.returncode != 0 or (server.calls != ['create', 'file_write', 'file_read', 'file_read', 'command', 'command_ack', 'kill'] or not server.files_ok or not server.command_ok):
            raise RuntimeError(f'App exit={result.returncode}, calls={server.calls}')
        print('macOS sandbox local network passed: create, file write/read/stream, command output, kill')
    finally:
        server.shutdown()
        worker.join()
