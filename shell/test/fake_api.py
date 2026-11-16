#!/usr/bin/env python3
"""A stand-in for the CarNET API, for testing carnet-folder.sh without spending requests.

It answers like the Cloud API, including the limit headers and the 429 refusals, but decides each answer from the
photo's first bytes instead of recognizing anything:

    CAR...      one car              NOCAR...    no car
    TWOCARS...  two cars             MMONLY...   one car, make and model only
    BAD...      unreadable photo     FLAKY...    HTTP 500 the first time, then one car
    REVOKED...  HTTP 403, as if the key had been revoked just now

Usage: fake_api.py PORT [--rate N] [--quota N] [--quota-seconds S] [--no-key]
Writes one line per request to stdout: "<status> <what>". Only for tests; never expose it.
"""
import hashlib
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

KEY = "test-key"
args = sys.argv[1:]
PORT = int(args[0])
RATE = int(args[args.index("--rate") + 1]) if "--rate" in args else 2
QUOTA = int(args[args.index("--quota") + 1]) if "--quota" in args else 1000
QUOTA_SECONDS = float(args[args.index("--quota-seconds") + 1]) if "--quota-seconds" in args else 86400
NO_KEY = "--no-key" in args  # CarNET Server: no key and no daily limit, only the per-second one

lock = threading.Lock()
rate_window = {"start": 0.0, "used": 0}
quota_window = {"start": 0.0, "used": 0}
seen = set()


def count(window, length, limit, now):
    """A fixed window that starts at the first request after the previous one ended, as the Cloud API counts."""
    if now >= window["start"] + length:
        window["start"], window["used"] = now, 0
    window["used"] += 1
    return window["used"] <= limit, max(limit - window["used"], 0), int((window["start"] + length) * 1000)


def car(make, model, generation, years):
    return {
        "box": {"tl_x": 0.1, "tl_y": 0.2, "br_x": 0.9, "br_y": 0.8},
        "class": {"name": "car", "probability": 0.99},
        "subclass": [{"name": "vehicle", "probability": 0.99}],
        "status": {"code": 0, "message": "", "selected": True},
        "mmg": [{"make_id": 1, "make_name": make, "model_id": 2, "model_name": model, "generation_id": 3,
                 "generation_name": generation, "years": years, "probability": 0.9871}],
        "color": [{"id": 70, "name": "Black", "probability": 0.95}],
        "angle": [{"name": "front-left", "probability": 1.0}],
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def send(self, status, body, headers=()):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        for name, value in headers:
            self.send_header(name, str(value))
        self.end_headers()
        self.wfile.write(data)
        print(status, body.get("message") or body.get("what", ""), flush=True)

    def do_POST(self):
        photo = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        query = parse_qs(urlparse(self.path).query)
        if urlparse(self.path).path != "/detect":
            return self.send(404, {"message": "Not found"})

        headers = []
        if NO_KEY:
            with lock:
                ok, left, reset = count(rate_window, 1.0, RATE, time.time())
            headers = [("X-Rate-Limit-Limit", RATE), ("X-Rate-Limit-Remaining", left), ("X-Rate-Limit-Reset", reset)]
            if not ok:
                return self.send(429, {"message": f"Rate limit exceeded ! You reach the limit of {RATE} requests per 1 seconds",
                                       "http_status_code": 429}, headers)
        else:
            key = self.headers.get("api-key")
            if not key:
                return self.send(401, {"message": "Unauthorized", "http_status_code": 401})
            if key != KEY or photo.startswith(b"REVOKED"):
                return self.send(403, {"message": "API Key is not valid or is expired / revoked.", "http_status_code": 403})
            with lock:
                now = time.time()
                ok, left, reset = count(rate_window, 1.0, RATE, now)
                headers = [("X-Rate-Limit-Limit", RATE), ("X-Rate-Limit-Remaining", left), ("X-Rate-Limit-Reset", reset)]
                if not ok:  # a rate refusal never reaches the quota
                    return self.send(429, {"message": f"Rate limit exceeded ! You reach the limit of {RATE} requests per 1 seconds",
                                           "http_status_code": 429}, headers)
                ok, left, reset = count(quota_window, QUOTA_SECONDS, QUOTA, now)
                headers += [("X-Quota-Limit", QUOTA), ("X-Quota-Remaining", left), ("X-Quota-Reset", reset)]
                if not ok:
                    return self.send(429, {"message": f"Quota exceeded ! You reach the limit of {QUOTA} requests per 1 days",
                                           "http_status_code": 429}, headers)

        if query.get("box_select", ["center"])[0] not in ("all", "center", "largest"):
            return self.send(200, {"is_success": False, "error": {"code": 15, "message": "Unsupported parameter values: box_select"},
                                   "what": "bad parameter"}, headers)

        digest = hashlib.md5(photo).hexdigest()
        meta = {"classifier": 2267, "md5": digest.upper(), "time": 0.05}
        if photo.startswith(b"FLAKY") and digest not in seen:
            seen.add(digest)
            return self.send(500, {"what": "server error"}, headers)
        if photo.startswith(b"TWOCARS"):
            return self.send(200, {"is_success": True, "detections": [car("Porsche", "Taycan", "I facelift", "2024-"),
                                                                      car("Volvo", "XC60", "I facelift", "2013-2017")],
                                   "meta": meta, "what": "two cars"}, headers)
        if photo.startswith(b"MMONLY"):
            only = car("Porsche", "Taycan", "", "")
            only["mm"] = [{key: only["mmg"][0][key] for key in ("make_id", "make_name", "model_id", "model_name", "probability")}]
            del only["mmg"]
            return self.send(200, {"is_success": True, "detections": [only], "meta": meta, "what": "make and model"}, headers)
        if photo.startswith(b"CAR") or photo.startswith(b"FLAKY"):
            return self.send(200, {"is_success": True, "detections": [car("Porsche", "Taycan", "I facelift", "2024-")],
                                   "meta": meta, "what": "car"}, headers)
        if photo.startswith(b"NOCAR"):
            return self.send(200, {"is_success": True, "detections": [], "meta": meta, "what": "no car"}, headers)
        return self.send(200, {"is_success": False, "error": {"code": 8, "message": "Failed to decode image"},
                               "what": "unreadable"}, headers)


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
