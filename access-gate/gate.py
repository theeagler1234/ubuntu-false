"""Access-code gate that sits in front of the Webtop desktop.

Visitors must enter ACCESS_CODE once. After that a signed cookie lets them
through, and every request (including the desktop's websockets) is proxied
to UPSTREAM. Nothing reaches the desktop without a valid cookie.
"""

import asyncio
import hashlib
import hmac
import html
import os
import time
from collections import defaultdict

import aiohttp
from aiohttp import web

ACCESS_CODE = os.environ.get("ACCESS_CODE", "")
UPSTREAM = os.environ.get("UPSTREAM", "http://ubuntu-desktop:3000").rstrip("/")
LISTEN_PORT = int(os.environ.get("GATE_PORT", "3000"))
COOKIE_NAME = "desktop_access"
COOKIE_DAYS = int(os.environ.get("COOKIE_DAYS", "30"))
MAX_FAILS = 5
LOCKOUT_SECONDS = 60

if not ACCESS_CODE:
    raise SystemExit("ACCESS_CODE is not set - refusing to start an open gate.")

# The cookie value is derived from the code, so changing the code logs everyone out.
_KEY = hashlib.sha256(b"gate-cookie-key:" + ACCESS_CODE.encode()).digest()


def make_token(expires: int) -> str:
    sig = hmac.new(_KEY, str(expires).encode(), hashlib.sha256).hexdigest()
    return f"{expires}.{sig}"


def token_valid(token: str | None) -> bool:
    if not token or "." not in token:
        return False
    expires_s, sig = token.split(".", 1)
    try:
        expires = int(expires_s)
    except ValueError:
        return False
    if expires < time.time():
        return False
    expected = hmac.new(_KEY, expires_s.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(sig, expected)


def is_authed(request: web.Request) -> bool:
    return token_valid(request.cookies.get(COOKIE_NAME))


# --- brute-force protection -------------------------------------------------
_fails: dict[str, list[float]] = defaultdict(list)


def client_id(request: web.Request) -> str:
    fwd = request.headers.get("X-Forwarded-For", "")
    return fwd.split(",")[0].strip() if fwd else (request.remote or "unknown")


def locked_out(cid: str) -> int:
    now = time.time()
    recent = [t for t in _fails[cid] if now - t < LOCKOUT_SECONDS]
    _fails[cid] = recent
    if len(recent) >= MAX_FAILS:
        return int(LOCKOUT_SECONDS - (now - recent[0])) + 1
    return 0


# --- unlock page ------------------------------------------------------------
PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Access code required</title>
<style>
  :root {{ color-scheme: dark; }}
  body {{ margin:0; min-height:100vh; display:grid; place-items:center;
         background:#14171a; color:#e6e8ea;
         font:16px/1.5 system-ui,-apple-system,Segoe UI,sans-serif; }}
  main {{ width:min(92vw,28rem); padding:2rem; background:#1e2327;
         border:1px solid #2f363c; border-radius:12px; }}
  h1 {{ margin:0 0 .25rem; font-size:1.25rem; }}
  p {{ margin:0 0 1.25rem; color:#9aa4ac; }}
  input {{ width:100%; box-sizing:border-box; padding:.7rem .8rem; font:inherit;
          color:inherit; background:#14171a; border:1px solid #3a434a;
          border-radius:8px; }}
  input:focus {{ outline:2px solid #e95420; border-color:transparent; }}
  button {{ margin-top:.9rem; width:100%; padding:.7rem; font:inherit;
           font-weight:600; color:#fff; background:#e95420; border:0;
           border-radius:8px; cursor:pointer; }}
  button:hover {{ background:#f26a3a; }}
  .err {{ margin:.9rem 0 0; color:#ff8a80; }}
</style></head>
<body><main>
  <h1>Enter the access code</h1>
  <p>You need the special code before you can open this desktop.</p>
  <form method="post" action="/__gate/unlock" autocomplete="off">
    <input type="password" name="code" placeholder="Access code" autofocus required>
    <button type="submit">Unlock</button>
    {error}
  </form>
</main></body></html>
"""


def page(error: str = "", status: int = 401) -> web.Response:
    err_html = f'<p class="err">{html.escape(error)}</p>' if error else ""
    return web.Response(
        text=PAGE.format(error=err_html),
        status=status,
        content_type="text/html",
        headers={"Cache-Control": "no-store"},
    )


async def health(_request: web.Request) -> web.Response:
    return web.Response(text="ok")


async def unlock(request: web.Request) -> web.Response:
    cid = client_id(request)
    wait = locked_out(cid)
    if wait:
        return page(f"Too many wrong attempts. Try again in {wait}s.", 429)

    form = await request.post()
    code = str(form.get("code", ""))
    if not hmac.compare_digest(code.encode(), ACCESS_CODE.encode()):
        _fails[cid].append(time.time())
        return page("That code is not right.")

    _fails.pop(cid, None)
    expires = int(time.time()) + COOKIE_DAYS * 86400
    secure = (
        request.secure
        or request.headers.get("X-Forwarded-Proto", "").split(",")[0].strip() == "https"
    )
    resp = web.HTTPSeeOther("/")
    resp.set_cookie(
        COOKIE_NAME,
        make_token(expires),
        max_age=COOKIE_DAYS * 86400,
        httponly=True,
        samesite="Lax",
        secure=secure,
        path="/",
    )
    return resp


# --- reverse proxy ----------------------------------------------------------
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade",
}
WS_HANDSHAKE = {
    "sec-websocket-key", "sec-websocket-version", "sec-websocket-extensions",
    "sec-websocket-protocol", "sec-websocket-accept",
}


def forward_headers(request: web.Request, drop_ws: bool = False) -> dict:
    out = {}
    for k, v in request.headers.items():
        lk = k.lower()
        if lk in HOP_BY_HOP or lk == "content-length":
            continue
        if drop_ws and lk in WS_HANDSHAKE:
            continue
        # Don't leak the gate cookie to the desktop.
        if lk == "cookie":
            parts = [c for c in v.split(";") if not c.strip().startswith(COOKIE_NAME + "=")]
            if not parts:
                continue
            v = ";".join(parts)
        out[k] = v
    out["X-Forwarded-For"] = client_id(request)
    out["X-Forwarded-Proto"] = request.headers.get("X-Forwarded-Proto", request.scheme)
    out["X-Forwarded-Host"] = request.host
    return out


async def proxy_ws(request: web.Request) -> web.StreamResponse:
    protocols = [
        p.strip()
        for p in request.headers.get("Sec-WebSocket-Protocol", "").split(",")
        if p.strip()
    ]
    session: aiohttp.ClientSession = request.app["session"]
    url = UPSTREAM.replace("http", "ws", 1) + request.path_qs
    try:
        upstream = await session.ws_connect(
            url,
            headers=forward_headers(request, drop_ws=True),
            protocols=protocols,
            max_msg_size=0,
            autoclose=False,
            autoping=False,
        )
    except aiohttp.ClientError:
        return web.Response(status=502, text="Desktop is not reachable yet.")

    client = web.WebSocketResponse(
        protocols=[upstream.protocol] if upstream.protocol else [],
        max_msg_size=0,
        autoclose=False,
        autoping=False,
    )
    await client.prepare(request)

    async def pump(src, dst):
        async for msg in src:
            if msg.type == aiohttp.WSMsgType.TEXT:
                await dst.send_str(msg.data)
            elif msg.type == aiohttp.WSMsgType.BINARY:
                await dst.send_bytes(msg.data)
            elif msg.type == aiohttp.WSMsgType.PING:
                await dst.ping(msg.data)
            elif msg.type == aiohttp.WSMsgType.PONG:
                await dst.pong(msg.data)
            else:
                break

    tasks = [
        asyncio.ensure_future(pump(client, upstream)),
        asyncio.ensure_future(pump(upstream, client)),
    ]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for t in tasks:
            t.cancel()
        await upstream.close()
        await client.close()
    return client


async def proxy_http(request: web.Request) -> web.StreamResponse:
    session: aiohttp.ClientSession = request.app["session"]
    try:
        async with session.request(
            request.method,
            UPSTREAM + request.path_qs,
            headers=forward_headers(request),
            data=request.content if request.can_read_body else None,
            allow_redirects=False,
        ) as up:
            resp = web.StreamResponse(status=up.status, reason=up.reason)
            for k, v in up.headers.items():
                if k.lower() in HOP_BY_HOP or k.lower() == "content-length":
                    continue
                resp.headers.add(k, v)
            await resp.prepare(request)
            async for chunk in up.content.iter_chunked(64 * 1024):
                await resp.write(chunk)
            await resp.write_eof()
            return resp
    except aiohttp.ClientError:
        return web.Response(status=502, text="Desktop is not reachable yet.")


@web.middleware
async def gate(request: web.Request, handler):
    if request.path in ("/__gate/health", "/__gate/unlock"):
        return await handler(request)
    if not is_authed(request):
        return page()
    return await handler(request)


async def proxy(request: web.Request) -> web.StreamResponse:
    if request.headers.get("Upgrade", "").lower() == "websocket":
        return await proxy_ws(request)
    return await proxy_http(request)


async def on_startup(app: web.Application) -> None:
    app["session"] = aiohttp.ClientSession(
        auto_decompress=False,
        connector=aiohttp.TCPConnector(ssl=False),
        timeout=aiohttp.ClientTimeout(total=None, sock_connect=10),
    )


async def on_cleanup(app: web.Application) -> None:
    await app["session"].close()


def build_app() -> web.Application:
    app = web.Application(middlewares=[gate], client_max_size=0)
    app.router.add_get("/__gate/health", health)
    app.router.add_post("/__gate/unlock", unlock)
    app.router.add_route("*", "/{tail:.*}", proxy)
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    return app


if __name__ == "__main__":
    web.run_app(build_app(), host="0.0.0.0", port=LISTEN_PORT, access_log=None)
