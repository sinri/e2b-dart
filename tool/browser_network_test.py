"""Run a real browser test against an isolated local CORS peer.
Usage: python3 tool/browser_network_test.py /path/to/dart [chrome executable]
Port 18763 must be free. No E2B credentials or cloud resources are used.
"""
from email.parser import BytesParser
from email.policy import default
import gzip
import http.server
import json
import os
import subprocess
import sys
import threading


class Peer(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', '*')

    def do_OPTIONS(self):
        self.server.preflights += 1
        self.send_response(204)
        self.cors()
        self.end_headers()

    def do_PUT(self):
        data = self.rfile.read(int(self.headers['Content-Length']))
        valid = (self.path == '/volumecontent/browser-volume/file?path=%2Fdata'
                 and data == bytes([0, 255, 1, 2])
                 and self.headers.get('Authorization') == 'Bearer volume-test-token'
                 and self.headers.get('X-API-Key') is None)
        self.server.volume_upload_ok = valid
        body = json.dumps({'path': '/data', 'name': 'data', 'type': 'file',
                           'size': len(data)} if valid else {'message': 'invalid volume request'}).encode()
        self.send_response(200 if valid else 400)
        self.cors()
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        data = self.rfile.read(int(self.headers['Content-Length']))
        if self.headers.get('Content-Encoding') == 'gzip':
            payload = gzip.decompress(data)
            valid = (self.path == '/files?path=%2Fgzip-upload'
                     and payload == bytes([0, 128, 255, 1, 2, 3])
                     and self.headers.get('X-Metadata-source') == 'browser')
            self.server.gzip_upload_ok = valid
            body = json.dumps([{'path': '/gzip-upload', 'name': 'gzip-upload',
                                'size': len(payload)}] if valid else {'message': 'invalid gzip upload'}).encode()
            self.send_response(200 if valid else 400)
            self.cors()
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        message = BytesParser(policy=default).parsebytes(
            ('Content-Type: ' + self.headers['Content-Type'] + '\r\n\r\n').encode() + data)
        parts = list(message.iter_parts())
        expected = [('/binary', bytes([0, 128, 255])), ('/text', '你好'.encode()),
                    ('/stream-input', bytes([1, 2, 3]))]
        actual = [(part.get_filename(), part.get_payload(decode=True)) for part in parts]
        valid = self.path.partition('?')[0] == '/files' and actual == expected
        self.server.upload_ok = valid
        body = json.dumps([{'path': path, 'name': path[1:], 'type': 'file', 'size': len(payload)}
                           for path, payload in expected] if valid else {'message': str(actual)}).encode()
        self.send_response(200 if valid else 400)
        self.cors()
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.server.requests += 1
        if self.path.startswith('/files?') and 'compressed' in self.path:
            body = gzip.compress(bytes([0, 128, 255, 1, 2, 3]))
            self.send_response(200)
            self.cors()
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Encoding', 'gzip')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith('/files?'):
            self.send_response(200)
            self.cors()
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', '6')
            self.end_headers()
            self.wfile.write(bytes([0, 128, 255]))
            self.wfile.flush()
            if 'cancel' in self.path:
                closed = self.server.file_signal_closed if 'signal' in self.path else self.server.file_closed
                self.connection.settimeout(5)
                try:
                    if self.connection.recv(1) == b'':
                        closed.set()
                except (ConnectionResetError, BrokenPipeError):
                    closed.set()
                except TimeoutError:
                    pass
                return
            if 'stream' in self.path:
                if not self.server.release_file.wait(5):
                    return
            self.wfile.write(bytes([1, 2, 3]))
            return
        if self.path == '/release-file':
            self.server.release_file.set()
        if self.path == '/slow':
            self.server.slow_started.set()
            self.connection.settimeout(5)
            try:
                if self.connection.recv(1) == b'':
                    self.server.slow_closed.set()
            except (ConnectionResetError, BrokenPipeError):
                self.server.slow_closed.set()
            except TimeoutError:
                pass
            return
        error = self.path == '/error'
        body = json.dumps({'message': 'browser forbidden'} if error else {
            'query': self.path.partition('?')[2],
            'key': self.headers.get('X-API-Key'),
        }).encode()
        if self.path == '/stats':
            body = json.dumps({'started': self.server.slow_started.is_set(),
                               'closed': self.server.slow_closed.is_set(),
                               'fileClosed': self.server.file_closed.is_set(),
                               'fileSignalClosed': self.server.file_signal_closed.is_set()}).encode()
        self.send_response(403 if error else 200)
        self.cors()
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


with http.server.ThreadingHTTPServer(('127.0.0.1', 18763), Peer) as server:
    server.preflights = 0
    server.requests = 0
    server.upload_ok = False
    server.gzip_upload_ok = False
    server.volume_upload_ok = False
    server.file_signal_closed = threading.Event()
    server.file_closed = threading.Event()
    server.release_file = threading.Event()
    server.slow_started = threading.Event()
    server.slow_closed = threading.Event()
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    env = dict(os.environ)
    if len(sys.argv) > 2:
        env['CHROME_EXECUTABLE'] = sys.argv[2]
    try:
        result = subprocess.run([sys.argv[1], 'test', '--platform', 'chrome',
                                 'test/browser_network_test.dart'], env=env)
        if result.returncode == 0 and (server.preflights < 1 or not server.slow_closed.is_set() or not server.file_closed.is_set() or not server.file_signal_closed.is_set() or not server.upload_ok or not server.gzip_upload_ok or not server.volume_upload_ok or server.requests < 5):
            raise RuntimeError(f'Unexpected peer traffic: {server.preflights} OPTIONS, {server.requests} GET')
        print(f'CORS peer: {server.preflights} OPTIONS, {server.requests} GET', flush=True)
        sys.exit(result.returncode)
    finally:
        server.shutdown()
        worker.join()
