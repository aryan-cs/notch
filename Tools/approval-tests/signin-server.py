# A copy of Microsoft's sign-in pages, close enough for Face Unlock's
# "finish signing in" (same element ids and wording), on 127.0.0.1:8799.
# Development builds treat it like Microsoft's sign-in. Every submitted page
# is logged, so a test can check what was pressed:
#
#   python3 signin-server.py presses.log
#   open http://127.0.0.1:8799/ms/password
#
# The password page comes with its password filled, as a browser fills it.
# Sign in and Continue should be pressed; "Stay signed in?" never should.
import http.server
import sys
import time
import urllib.parse

LOG = sys.argv[1]
PAGE = """<!doctype html><html><head><meta charset=utf-8><title>Notch sign-in test</title>
<style>body{{font-family:-apple-system;background:#2b4d2b;display:flex;justify-content:center;padding-top:80px}}
.box{{background:#fff;width:380px;padding:40px}} input[type=submit]{{background:#0067b8;color:#fff;border:0;padding:8px 32px;font-size:15px}}</style></head>
<body><div class=box><h2>NOTCH TEST</h2><div>test.user@example.edu</div><form method=post action="{action}">{body}</form></div></body></html>"""
PAGES = {
    "/ms/password": ("<div role=heading aria-level=1>Enter password</div>"
                     "<input name=passwd type=password id=i0118 value='test-password-123' aria-label='Enter the password'>"
                     "<p><a href='#'>Forgot my password</a></p><input type=submit id=idSIButton9 value='Sign in'>", "/ms/verify"),
    "/ms/verify": ("<div role=heading aria-level=1>Verification Required</div>"
                   "<p>You will be redirected to Duo to verify your identity</p><input type=submit id=idSIButton9 value='Continue'>", "/ms/kmsi"),
    "/ms/kmsi": ("<div role=heading aria-level=1>Stay signed in?</div><p>Do this to reduce the number of times you are asked to sign in.</p>"
                 "<label><input type=checkbox name=DontShowAgain> Don't show this again</label>"
                 "<input type=submit id=idBtn_Back value='No'> <input type=submit id=idSIButton9 value='Yes'>", "/ms/done"),
    "/ms/done": ("<div role=heading aria-level=1>Signed in (test)</div>", "/ms/done"),
}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.split("?")[0]
        if path not in PAGES:
            self.send_response(404)
            self.end_headers()
            return
        body, action = PAGES[path]
        data = PAGE.format(action=action, body=body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        came_from = urllib.parse.urlparse(self.headers.get("Referer", "")).path or "?"
        with open(LOG, "a") as log:
            log.write(f"{time.strftime('%H:%M:%S')} submitted {came_from}\n")
        self.send_response(303)
        self.send_header("Location", self.path)
        self.end_headers()


http.server.ThreadingHTTPServer(("127.0.0.1", 8799), Handler).serve_forever()
