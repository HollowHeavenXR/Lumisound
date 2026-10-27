"""Pure-ASGI replacements for the three per-request middlewares.

`@app.middleware("http")` (BaseHTTPMiddleware) wraps every request in an extra
task + memory stream and buffers streaming bodies through it; two of them stacked
cost measurable latency on every call, audio streams included. Starlette's stock
GZipMiddleware also compresses at level 9 (slow) and will happily gzip audio and
images, which are already compressed, burns CPU, and drops Content-Length.

This does all three jobs in one thin ASGI layer:
  * gzip only text-like responses (level 4), never media or ranged replies
  * security headers
  * slow-request logging
"""
import gzip
import io
import logging
import time

logger = logging.getLogger("ios-bridge")

_SLOW_REQUEST_THRESHOLD = 2.0
_MIN_GZIP = 1024
_GZIP_LEVEL = 4
_COMPRESSIBLE = (b"application/json", b"text/", b"application/javascript",
                 b"application/xml", b"image/svg+xml")

_STATIC_HEADERS = (
    (b"x-content-type-options", b"nosniff"),
    (b"x-frame-options", b"DENY"),
    (b"referrer-policy", b"no-referrer"),
    (b"strict-transport-security", b"max-age=31536000; includeSubDomains"),
)
_CSP = (b"content-security-policy", b"default-src 'none'; frame-ancestors 'none'")


class PerfMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        start = time.monotonic()
        path = scope.get("path", "")
        wants_gzip = False
        for k, v in scope.get("headers", ()):
            if k == b"accept-encoding" and b"gzip" in v:
                wants_gzip = True
                break

        status = 0
        pending_start = None   # held until we see whether the body is gzip-able
        gz = None              # (GzipFile, BytesIO) once streaming-compressing
        passthrough = False

        def finish_headers(headers):
            have = {k for k, _ in headers}
            for k, v in _STATIC_HEADERS:
                if k not in have:
                    headers.append((k, v))
            if _CSP[0] not in have and not path.startswith("/admin"):
                headers.append(_CSP)
            return headers

        async def wrapped_send(message):
            nonlocal status, pending_start, gz, passthrough
            mtype = message["type"]

            if mtype == "http.response.start":
                status = message["status"]
                headers = finish_headers(list(message.get("headers", ())))
                message = {**message, "headers": headers}
                if not wants_gzip or status in (204, 206, 304):
                    passthrough = True
                    await send(message)
                    return
                d = {k: v for k, v in headers}
                ctype = d.get(b"content-type", b"").lower()
                if (b"content-encoding" in d or b"content-range" in d
                        or not ctype.startswith(_COMPRESSIBLE)):
                    passthrough = True
                    await send(message)
                    return
                pending_start = message
                return

            if mtype != "http.response.body" or passthrough:
                await send(message)
                return

            body = message.get("body", b"")
            more = message.get("more_body", False)

            if pending_start is not None:
                head, pending_start = pending_start, None
                if not more and len(body) < _MIN_GZIP:
                    passthrough = True
                    await send(head)
                    await send(message)
                    return
                headers = [(k, v) for k, v in head["headers"]
                           if k not in (b"content-length", b"vary")]
                vary = next((v for k, v in head["headers"] if k == b"vary"), None)
                headers.append((b"vary", (vary + b", Accept-Encoding") if vary
                                else b"Accept-Encoding"))
                headers.append((b"content-encoding", b"gzip"))
                if not more:
                    out = gzip.compress(body, compresslevel=_GZIP_LEVEL)
                    headers.append((b"content-length", str(len(out)).encode()))
                    passthrough = True
                    await send({**head, "headers": headers})
                    await send({**message, "body": out})
                    return
                buf = io.BytesIO()
                gz = (gzip.GzipFile(mode="wb", fileobj=buf, compresslevel=_GZIP_LEVEL), buf)
                await send({**head, "headers": headers})

            if gz is not None:
                f, buf = gz
                f.write(body)
                if not more:
                    f.close()
                out = buf.getvalue()
                buf.seek(0)
                buf.truncate()
                await send({**message, "body": out})
                return
            await send(message)

        try:
            await self.app(scope, receive, wrapped_send)
        finally:
            elapsed = time.monotonic() - start
            if elapsed > _SLOW_REQUEST_THRESHOLD:
                logger.warning("slow request: %s %s took %.2fs (status %d)",
                               scope.get("method"), path, elapsed, status)
