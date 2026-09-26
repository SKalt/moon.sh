#!/usr/bin/env python3
"""Local OAuth redirect server for the Gravatar authorization code flow.

Start it, then open http://localhost:5000/ . The server redirects you to
Gravatar's authorize endpoint requesting the `auth` and
`gravatar-profile:manage` scopes; once you approve, Gravatar redirects back
to /callback with an authorization code. The server exchanges that code for a
non-expiring access token, verifies its scope, and saves it to the shared
token file (default: ${XDG_CACHE_HOME:-~/.cache}/zamoon/gravatar.token),
which scripts/lib.sh's gravatar_access_token reads.

Required env: GRAVATAR_CLIENT_ID, GRAVATAR_CLIENT_SECRET (or GRAVATAR_API_KEY)
Optional env: GRAVATAR_REDIRECT_URI, GRAVATAR_TOKEN_FILE, GRAVATAR_SCOPE
"""

from __future__ import annotations

import html
import json
import os
import re
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HOST = "localhost"
PORT = 5000
OAUTH = "https://public-api.wordpress.com/oauth2"
REQUIRED_SCOPES = ("auth", "gravatar-profile:manage")
STATE = secrets.token_urlsafe(32)

TOKEN_ENDPOINT = f"{OAUTH}/token"
TOKEN_INFO_ENDPOINT = f"{OAUTH}/token-info"


def scopes() -> tuple[str, ...]:
    raw = os.environ.get("GRAVATAR_SCOPE", "")
    return tuple(raw.split()) if raw.strip() else REQUIRED_SCOPES


def redirect_uri() -> str:
    return os.environ.get("GRAVATAR_REDIRECT_URI", f"http://{HOST}:{PORT}/callback")


def token_file() -> Path:
    if override := os.environ.get("GRAVATAR_TOKEN_FILE"):
        return Path(override)
    cache = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(cache) / "zamoon" / "gravatar.token"


def client_id() -> str:
    value = os.environ.get("GRAVATAR_CLIENT_ID")
    if not value:
        raise SystemExit("GRAVATAR_CLIENT_ID is required")
    return value


def client_secret() -> str:
    value = os.environ.get("GRAVATAR_CLIENT_SECRET") or os.environ.get("GRAVATAR_API_KEY")
    if not value:
        raise SystemExit("GRAVATAR_CLIENT_SECRET or GRAVATAR_API_KEY is required")
    return value


def authorize_url() -> str:
    params = [
        ("client_id", client_id()),
        ("redirect_uri", redirect_uri()),
        ("response_type", "code"),
        ("state", STATE),
    ]
    params += [(f"scope[{i}]", scope) for i, scope in enumerate(scopes())]
    return f"{OAUTH}/authorize?" + urllib.parse.urlencode(params)


def exchange_code(code: str) -> dict:
    data = urllib.parse.urlencode(
        {
            "client_id": client_id(),
            "client_secret": client_secret(),
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect_uri(),
        }
    ).encode()
    request = urllib.request.Request(
        TOKEN_ENDPOINT,
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def token_scope(token: str) -> str | None:
    """Return the granted scope string, or None if it could not be verified."""
    query = urllib.parse.urlencode({"client_id": client_id(), "token": token})
    try:
        with urllib.request.urlopen(f"{TOKEN_INFO_ENDPOINT}?{query}") as response:
            return json.load(response).get("scope", "")
    except (urllib.error.URLError, TimeoutError, ValueError):
        return None


def html_page(title: str, body: str) -> str:
    return (
        "<!doctype html><html><head><meta charset='utf-8'>"
        f"<title>{html.escape(title)}</title></head>"
        f"<body style='font-family:sans-serif'><h1>{html.escape(title)}</h1>"
        f"<p>{body}</p></body></html>"
    )


class Handler(BaseHTTPRequestHandler):
    done: int | None = None  # process exit code once the flow has finished

    def log_message(self, format: str, *args) -> None:
        print(f"[oauth] {self.address_string()} - {format % args}", flush=True)

    def _send(self, status: int, body: str, location: str | None = None) -> None:
        payload = body.encode()
        self.send_response(status)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)

        if parsed.path == "/" and not query:
            self._send(302, "", location=authorize_url())
            return

        # callbacks land on /callback, or on / when GRAVATAR_REDIRECT_URI is the root
        if parsed.path.rstrip("/") not in ("", "/callback"):
            self._send(404, html_page("Not found", "Unknown path."))
            return

        if "error" in query or "access_denied" in query:
            error = query.get("error", ["access_denied"])[0]
            message = query.get("error_description", [""])[0]
            print(f"[oauth] authorization denied: {error} {message}", file=sys.stderr)
            self._send(400, html_page("Authorization denied", f"{html.escape(error)} {html.escape(message)}"))
            Handler.done = 1
            return

        if query.get("state", [""])[0] != STATE:
            print("[oauth] invalid state in callback; rejecting", file=sys.stderr)
            self._send(400, html_page("Invalid state", "State mismatch. Start again from <a href='/'>/</a>"))
            Handler.done = 1
            return

        code = query.get("code", [""])[0]
        if not code:
            self._send(400, html_page("Missing code", "No authorization code in the callback."))
            Handler.done = 1
            return

        try:
            payload = exchange_code(code)
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            print(f"[oauth] token exchange failed ({error.code}): {detail}", file=sys.stderr)
            hint = ""
            if "redirect_uri" in detail:
                hint = (
                    "<br><br>Hint: the redirect_uri must match both the authorize step and a "
                    "Redirect URL registered for your application at "
                    "<a href='https://gravatar.com/developers'>gravatar.com/developers</a> "
                    "(http vs https, port, path, and trailing slash all matter). "
                    "Restart this server with GRAVATAR_REDIRECT_URI set to the registered value."
                )
            self._send(500, html_page("Token exchange failed", html.escape(detail) + hint))
            Handler.done = 1
            return
        except (urllib.error.URLError, TimeoutError) as error:
            print(f"[oauth] token exchange failed: {error}", file=sys.stderr)
            self._send(500, html_page("Token exchange failed", html.escape(str(error))))
            Handler.done = 1
            return

        token = payload.get("access_token")
        if not token:
            print("[oauth] token response had no access_token", file=sys.stderr)
            self._send(500, html_page("Token exchange failed", "No access_token in response."))
            Handler.done = 1
            return

        granted = token_scope(token)
        if granted is not None:
            parts = set(part for part in re.split(r"[,\s]+", granted) if part)
            missing = [scope for scope in REQUIRED_SCOPES if scope not in parts]
            if missing:
                print(f"[oauth] token is missing required scopes: {', '.join(missing)}", file=sys.stderr)
                self._send(500, html_page("Missing scopes", f"Token scope is missing: {html.escape(', '.join(missing))}"))
                Handler.done = 1
                return
        else:
            print("[oauth] warning: could not verify the token's scopes", file=sys.stderr)

        path = token_file()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(token)
        os.chmod(path, 0o600)
        print(f"[oauth] access token saved to {path}", flush=True)
        self._send(200, html_page("Success", "Access token saved. You may close this tab."))
        Handler.done = 0


def main() -> int:
    client_id()
    client_secret()
    try:
        server = HTTPServer((HOST, PORT), Handler)
    except OSError as error:
        print(
            f"cannot bind {HOST}:{PORT}: {error}\n"
            "is something already listening there? (macOS AirPlay Receiver uses "
            "port 5000 by default).",
            file=sys.stderr,
        )
        return 1

    print(f"listening on http://{HOST}:{PORT}/", flush=True)
    print(f"redirect uri: {redirect_uri()}", flush=True)
    print(
        "  this must exactly match a Redirect URL registered for your application\n"
        "  at https://gravatar.com/developers (http vs https, port, path, and\n"
        "  trailing slash all matter). If you registered a different URL, restart\n"
        "  with GRAVATAR_REDIRECT_URI set to that exact value.",
        flush=True,
    )
    print(f"authorize url: {authorize_url()}", flush=True)
    try:
        while Handler.done is None:
            server.handle_request()
        exit_code = Handler.done
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        exit_code = 130
    finally:
        server.server_close()
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
