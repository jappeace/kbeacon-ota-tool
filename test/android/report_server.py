#!/usr/bin/env python3
# Tiny HTTP sink for the UI test's report phase.
#
# The app in the emulator POSTs each beacon's configuration result to
# http://10.0.2.2:<port>/report (10.0.2.2 is the emulator's alias for
# the host). Every request body is printed as one "REPORT: <body>"
# line, which the test harness asserts on.
#
# Usage: report_server.py <port>

import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class ReportHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        body = self.rfile.read(length).decode('utf-8', errors='replace')
        print(f'REPORT: {body}', flush=True)
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"received":true}')

    def log_message(self, format, *args):
        # BaseHTTPRequestHandler logs to stderr by default; keep stdout
        # clean for the REPORT lines.
        del format, args


def main():
    port = int(sys.argv[1])
    server = HTTPServer(('0.0.0.0', port), ReportHandler)
    print(f'REPORT_SERVER_LISTENING: {port}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
