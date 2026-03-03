#!/usr/bin/env python3
"""Simple HTTP model distribution server.
Serves GGUF model files and manifest on port 9191.

Usage:
    python server.py
    python server.py --port 9191 --dir /path/to/models
"""

import argparse
import json
import logging
import os
import sys
from http import HTTPStatus
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

DEFAULT_PORT = 9191


class ModelServerHandler(SimpleHTTPRequestHandler):
    """HTTP handler with range request support for model file downloads."""

    def do_GET(self):
        # Special handling for /manifest.json
        if self.path == "/manifest.json":
            self.serve_manifest()
            return

        # Check if client requested a range
        range_header = self.headers.get("Range")
        if range_header:
            self.serve_range_request(range_header)
            return

        # Default: serve file normally
        super().do_GET()

    def serve_manifest(self):
        """Serve manifest.json from the serving directory."""
        manifest_path = os.path.join(self.directory, "manifest.json")
        if not os.path.exists(manifest_path):
            self.send_error(HTTPStatus.NOT_FOUND, "manifest.json not found")
            return

        with open(manifest_path, "rb") as f:
            content = f.read()

        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(content)

    def serve_range_request(self, range_header: str):
        """Handle HTTP range requests for download resume support."""
        # Parse file path
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            self.send_error(HTTPStatus.NOT_FOUND)
            return

        file_size = os.path.getsize(path)

        # Parse Range header (e.g., "bytes=1000-2000" or "bytes=1000-")
        try:
            range_spec = range_header.replace("bytes=", "")
            parts = range_spec.split("-")
            start = int(parts[0]) if parts[0] else 0
            end = int(parts[1]) if parts[1] else file_size - 1
        except (ValueError, IndexError):
            self.send_error(HTTPStatus.BAD_REQUEST, "Invalid Range header")
            return

        if start >= file_size or end >= file_size or start > end:
            self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
            self.send_header("Content-Range", f"bytes */{file_size}")
            self.end_headers()
            return

        content_length = end - start + 1

        self.send_response(HTTPStatus.PARTIAL_CONTENT)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(content_length))
        self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()

        with open(path, "rb") as f:
            f.seek(start)
            remaining = content_length
            chunk_size = 64 * 1024  # 64KB chunks
            while remaining > 0:
                read_size = min(chunk_size, remaining)
                data = f.read(read_size)
                if not data:
                    break
                self.wfile.write(data)
                remaining -= len(data)

    def do_HEAD(self):
        """Handle HEAD requests (for checking file size before download)."""
        path = self.translate_path(self.path)
        if os.path.isfile(path):
            file_size = os.path.getsize(path)
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(file_size))
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
        else:
            self.send_error(HTTPStatus.NOT_FOUND)

    def log_message(self, format, *args):
        """Override to use our logger."""
        logger.info(f"{self.client_address[0]} - {format % args}")


def parse_args():
    parser = argparse.ArgumentParser(description="WE model distribution server")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--dir", type=str, default=".",
                        help="Directory to serve files from")
    parser.add_argument("--bind", type=str, default="0.0.0.0",
                        help="Address to bind to")
    return parser.parse_args()


def main():
    args = parse_args()

    serve_dir = os.path.abspath(args.dir)
    if not os.path.isdir(serve_dir):
        logger.error(f"Directory not found: {serve_dir}")
        sys.exit(1)

    os.chdir(serve_dir)

    handler = ModelServerHandler
    handler.directory = serve_dir

    server = HTTPServer((args.bind, args.port), handler)
    logger.info(f"Serving models from {serve_dir}")
    logger.info(f"Listening on {args.bind}:{args.port}")
    logger.info(f"Manifest: http://{args.bind}:{args.port}/manifest.json")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
