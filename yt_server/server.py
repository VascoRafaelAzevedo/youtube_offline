#!/usr/bin/env python3
"""
YouTube Download Server using yt-dlp
=====================================
A simple HTTP server that downloads YouTube videos using yt-dlp
and streams them back to the client (mobile app).

Features:
- Video cache (last 50 downloads)
- Sequential download queue (one at a time)
- Anti-bot delay between downloads
- Cookie support for authentication

Authentication: Simple API key in header
Quality options: max, 1080, 720, 360

Usage:
    python server.py [--port PORT] [--api-key YOUR_KEY]
"""

import argparse
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from collections import OrderedDict
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse
from pathlib import Path
from queue import Queue
from dataclasses import dataclass, field
from typing import Optional, Callable

# Configuration
DEFAULT_PORT = int(os.environ.get("PORT", 8765))
DEFAULT_API_KEY = os.environ.get("API_KEY", "offline_yt_secret_2025")

# Paths - support environment variables for Docker
DOWNLOADS_DIR = Path(os.environ.get("DOWNLOADS_DIR", str(Path.home() / "Downloads" / "OfflineYT_Server")))
TEMP_DIR = Path(os.environ.get("TEMP_DIR", str(Path(tempfile.gettempdir()) / "yt_server_temp")))
CACHE_DIR = Path(os.environ.get("CACHE_DIR", str(DOWNLOADS_DIR / "cache")))

# Cache settings
MAX_CACHE_SIZE = int(os.environ.get("MAX_CACHE_SIZE", 50))  # Number of videos to cache

# Anti-bot settings - critical for avoiding YouTube blocks
NORMAL_DELAY = (3, 6)              # Normal delay between downloads (seconds)
BOT_COOLDOWN = (30, 60)            # Cooldown after bot detection (seconds)
MAX_FAILS_PER_VIDEO = 2            # Max attempts per video before giving up
FAIL_MEMORY_TIME = 300             # How long to remember failed videos (5 min)

# Cookies file path (optional - for bypassing bot detection)
COOKIES_FILE = os.environ.get("COOKIES_FILE", "")
if not COOKIES_FILE:
    for cookies_path in [
        Path(__file__).parent / "cookies.txt",
        Path.home() / ".config" / "yt-dlp" / "cookies.txt",
        Path("/app/cookies.txt"),
    ]:
        if cookies_path.exists():
            COOKIES_FILE = str(cookies_path)
            break

# Path to yt-dlp
YTDLP_PATH = os.environ.get("YTDLP_PATH", "")
if not YTDLP_PATH:
    local_path = Path.home() / ".local" / "bin" / "yt-dlp"
    YTDLP_PATH = str(local_path) if local_path.exists() else "yt-dlp"

# Global state
download_lock = threading.Lock()
active_downloads = {}
download_queue = Queue()
video_cache = OrderedDict()  # video_id -> {path, size, quality, timestamp}
cache_lock = threading.Lock()
last_download_time = 0

# Anti-bot state
last_bot_detection = 0
failed_videos = {}  # video_id -> {"count": int, "last_fail": timestamp, "is_bot": bool}
failed_lock = threading.Lock()


def sanitize_filename(name: str, for_http_header: bool = False) -> str:
    """Remove invalid characters from filename."""
    sanitized = re.sub(r'[<>:"/\\|?*]', '', name)
    if for_http_header:
        sanitized = sanitized.replace('？', '').replace('：', '-').replace('！', '!')
        sanitized = sanitized.encode('ascii', 'ignore').decode('ascii')
    sanitized = re.sub(r'\s+', ' ', sanitized).strip()
    if len(sanitized) > 100:
        sanitized = sanitized[:100]
    return sanitized if sanitized else "video"


def load_cache_index():
    """Load cache index from disk."""
    global video_cache
    cache_index_file = CACHE_DIR / "cache_index.json"
    
    if cache_index_file.exists():
        try:
            with open(cache_index_file, 'r') as f:
                data = json.load(f)
                video_cache = OrderedDict(data.get("videos", {}))
                
            # Verify cached files still exist
            to_remove = []
            for video_id, info in video_cache.items():
                if not Path(info["path"]).exists():
                    to_remove.append(video_id)
            
            for video_id in to_remove:
                video_cache.pop(video_id, None)
            
            print(f"[CACHE] Loaded {len(video_cache)} videos from cache")
        except Exception as e:
            print(f"[CACHE] Error loading cache index: {e}")
            video_cache = OrderedDict()


def save_cache_index():
    """Save cache index to disk."""
    cache_index_file = CACHE_DIR / "cache_index.json"
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        with open(cache_index_file, 'w') as f:
            json.dump({"videos": dict(video_cache)}, f, indent=2)
    except Exception as e:
        print(f"[CACHE] Error saving cache index: {e}")


def add_to_cache(video_id: str, file_path: Path, quality: str) -> Path:
    """Add video to cache, evicting old entries if needed."""
    global video_cache
    
    with cache_lock:
        # Move file to cache directory
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        cache_path = CACHE_DIR / file_path.name
        
        # If same video already cached, remove old entry
        if video_id in video_cache:
            old_path = Path(video_cache[video_id]["path"])
            if old_path.exists() and old_path != cache_path:
                try:
                    old_path.unlink()
                except:
                    pass
            video_cache.pop(video_id)
        
        # Move file to cache
        if file_path != cache_path:
            shutil.move(str(file_path), str(cache_path))
        
        # Add to cache
        video_cache[video_id] = {
            "path": str(cache_path),
            "size": cache_path.stat().st_size,
            "quality": quality,
            "timestamp": time.time(),
            "filename": cache_path.name
        }
        
        # Move to end (most recently used)
        video_cache.move_to_end(video_id)
        
        # Evict oldest entries if cache is full
        while len(video_cache) > MAX_CACHE_SIZE:
            oldest_id, oldest_info = video_cache.popitem(last=False)
            oldest_path = Path(oldest_info["path"])
            if oldest_path.exists():
                try:
                    oldest_path.unlink()
                    print(f"[CACHE] Evicted: {oldest_id}")
                except:
                    pass
        
        save_cache_index()
        print(f"[CACHE] Added: {video_id} ({len(video_cache)}/{MAX_CACHE_SIZE} videos cached)")
        
        # Clear failed status on success - video is now working!
        with failed_lock:
            failed_videos.pop(video_id, None)
        
        return cache_path


def get_from_cache(video_id: str) -> Optional[dict]:
    """Get video from cache if exists."""
    with cache_lock:
        if video_id in video_cache:
            info = video_cache[video_id]
            if Path(info["path"]).exists():
                # Move to end (most recently used)
                video_cache.move_to_end(video_id)
                print(f"[CACHE] HIT: {video_id}")
                return info
            else:
                # File missing, remove from cache
                video_cache.pop(video_id)
                save_cache_index()
    return None


def get_quality_formats(quality: str) -> list:
    """Get list of yt-dlp format strings to try."""
    all_formats = [
        ("4K60", "bv*[height>=2160][fps>=50]+ba/b"),
        ("4K", "bv*[height>=2160]+ba/b"),
        ("1080p60", "bv*[height<=1080][fps>=50]+ba/b[height<=1080]/b"),
        ("1080p", "bv*[height<=1080]+ba/b[height<=1080]/b"),
        ("720p60", "bv*[height<=720][fps>=50]+ba/b[height<=720]/b"),
        ("720p", "bv*[height<=720]+ba/b[height<=720]/b"),
        ("480p", "bv*[height<=480]+ba/b[height<=480]/b"),
        ("360p", "bv*[height<=360]+ba/b[height<=360]/b"),
        ("worst", "worst"),
    ]
    
    start_index = {
        "max": 0,
        "1080": 2,
        "720": 4,
        "360": 7,
    }.get(quality, 2)
    
    return all_formats[start_index:]


def check_video_fail_status(video_id: str) -> dict:
    """Check if a video has failed too many times recently."""
    with failed_lock:
        # Clean old entries
        now = time.time()
        to_remove = [vid for vid, info in failed_videos.items() 
                     if now - info["last_fail"] > FAIL_MEMORY_TIME]
        for vid in to_remove:
            failed_videos.pop(vid, None)
        
        if video_id in failed_videos:
            info = failed_videos[video_id]
            if info["count"] >= MAX_FAILS_PER_VIDEO:
                wait_time = FAIL_MEMORY_TIME - (now - info["last_fail"])
                return {
                    "blocked": True,
                    "reason": f"Video failed {info['count']} times. Wait {int(wait_time)}s before retry.",
                    "wait_seconds": int(wait_time),
                    "fail_count": info["count"]
                }
            return {"blocked": False, "fail_count": info["count"]}
        
        return {"blocked": False, "fail_count": 0}


def record_video_failure(video_id: str, is_bot_error: bool):
    """Record a video download failure."""
    global last_bot_detection
    
    with failed_lock:
        if video_id not in failed_videos:
            failed_videos[video_id] = {"count": 0, "last_fail": 0, "is_bot": False}
        
        failed_videos[video_id]["count"] += 1
        failed_videos[video_id]["last_fail"] = time.time()
        
        if is_bot_error:
            failed_videos[video_id]["is_bot"] = True
    
    if is_bot_error:
        last_bot_detection = time.time()
        print(f"[BOT-DETECT] Recorded bot detection, activating {BOT_COOLDOWN[0]}-{BOT_COOLDOWN[1]}s cooldown")


def is_bot_error(error: str) -> bool:
    """Check if error is bot detection."""
    error_lower = error.lower()
    return any(x in error_lower for x in ["sign in", "bot", "confirm you're not"])


def wait_for_rate_limit():
    """Wait if needed to avoid bot detection."""
    global last_download_time, last_bot_detection
    
    now = time.time()
    
    # Check if we're in bot cooldown mode (after a bot detection)
    if last_bot_detection > 0:
        time_since_bot = now - last_bot_detection
        cooldown_needed = random.uniform(*BOT_COOLDOWN)
        
        if time_since_bot < cooldown_needed:
            wait_time = cooldown_needed - time_since_bot
            print(f"[BOT-COOLDOWN] Waiting {wait_time:.1f}s after bot detection...")
            time.sleep(wait_time)
            last_bot_detection = 0  # Reset after cooldown complete
    
    # Normal rate limiting between downloads
    if last_download_time > 0:
        elapsed = now - last_download_time
        required_delay = random.uniform(*NORMAL_DELAY)
        
        if elapsed < required_delay:
            wait_time = required_delay - elapsed
            print(f"[RATE-LIMIT] Waiting {wait_time:.1f}s before next download...")
            time.sleep(wait_time)
    
    last_download_time = time.time()


def download_video(video_id: str, format_string: str, quality_name: str) -> dict:
    """Download a YouTube video using yt-dlp."""
    url = f"https://www.youtube.com/watch?v={video_id}"
    
    TEMP_DIR.mkdir(parents=True, exist_ok=True)
    output_template = str(TEMP_DIR / f"{video_id}_%(title)s.%(ext)s")
    
    # Build yt-dlp command
    cmd = [
        YTDLP_PATH,
        "-f", format_string,
        "--merge-output-format", "mp4",
        "-o", output_template,
        "--no-playlist",
        "--newline",
        "--no-continue",
        "--no-part",
        "--retries", "3",
        "--fragment-retries", "3",
        "--sleep-requests", "1",  # Sleep between requests
        "--sleep-interval", "2",  # Sleep between downloads
        "--max-sleep-interval", "5",
        "--progress-template", "download:%(progress._percent_str)s of %(progress._total_bytes_str)s at %(progress._speed_str)s ETA %(progress._eta_str)s",
    ]
    
    # Add cookies if available
    if COOKIES_FILE and Path(COOKIES_FILE).exists():
        cmd.extend(["--cookies", COOKIES_FILE])
        print(f"[DOWNLOAD] Using cookies from: {COOKIES_FILE}")
    
    cmd.append(url)
    
    print(f"\n{'='*60}")
    print(f"[DOWNLOAD] Starting: {video_id}")
    print(f"[DOWNLOAD] Quality: {quality_name}")
    print(f"[DOWNLOAD] Format: {format_string}")
    print(f"{'='*60}")
    
    with download_lock:
        active_downloads[video_id] = {
            "status": "downloading",
            "phase": "yt-dlp",
            "progress": 0,
            "progress_text": "A iniciar download...",
            "started": time.time()
        }
    
    try:
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        
        error_output = []
        current_percent = 0
        
        for line in process.stdout:
            line = line.strip()
            if not line:
                continue
            
            if '%' in line and ('of' in line or 'ETA' in line):
                try:
                    percent_str = line.split('%')[0].strip().split()[-1]
                    current_percent = float(percent_str)
                except:
                    pass
                
                with download_lock:
                    if video_id in active_downloads:
                        active_downloads[video_id].update({
                            "progress": current_percent,
                            "progress_text": f"YouTube: {line}"
                        })
                
                print(f"\r[PROGRESS] {line}" + " " * 10, end="", flush=True)
            elif 'error' in line.lower() or 'ERROR' in line:
                print(f"\n[ERROR] {line}")
                error_output.append(line)
            elif 'Merging' in line:
                print(f"\n[STATUS] {line}")
                with download_lock:
                    if video_id in active_downloads:
                        active_downloads[video_id].update({
                            "status": "merging",
                            "progress_text": "A juntar vídeo e áudio..."
                        })
            elif 'Destination' in line:
                print(f"\n[FILE] {line}")
            elif line.startswith('['):
                print(f"[YT-DLP] {line}")
        
        print()
        return_code = process.wait(timeout=600)
        
        if return_code != 0:
            error_msg = "\n".join(error_output) if error_output else f"yt-dlp exited with code {return_code}"
            return {"success": False, "error": error_msg, "video_id": video_id}
        
        # Find output file
        output_files = list(TEMP_DIR.glob(f"{video_id}_*.mp4"))
        if not output_files:
            return {"success": False, "error": "Output file not found", "video_id": video_id}
        
        output_file = output_files[0]
        file_size = output_file.stat().st_size
        
        print(f"{'='*60}")
        print(f"[DOWNLOAD] SUCCESS: {output_file.name}")
        print(f"[DOWNLOAD] Size: {file_size / 1024 / 1024:.1f} MB")
        print(f"{'='*60}\n")
        
        return {
            "success": True,
            "path": str(output_file),
            "filename": output_file.name,
            "size": file_size,
            "video_id": video_id,
            "quality": quality_name
        }
        
    except subprocess.TimeoutExpired:
        process.kill()
        return {"success": False, "error": "Download timed out", "video_id": video_id}
    except Exception as e:
        return {"success": False, "error": str(e), "video_id": video_id}


def try_download_with_fallback(video_id: str, quality: str = "1080") -> dict:
    """Try to download, falling back to lower qualities if needed."""
    formats_to_try = get_quality_formats(quality)
    
    for i, (quality_name, format_string) in enumerate(formats_to_try):
        print(f"\n[FALLBACK] Trying format {i+1}/{len(formats_to_try)}: {quality_name}")
        
        result = download_video(video_id, format_string, quality_name)
        
        if result["success"]:
            return result
        
        error = result.get("error", "")
        
        # Check for bot detection - stop immediately, record failure
        if is_bot_error(error):
            print(f"[FALLBACK] Bot detection triggered - recording failure and stopping")
            record_video_failure(video_id, is_bot_error=True)
            return result
        
        # 403/format errors - try next format
        error_lower = error.lower()
        if "403" in error or "forbidden" in error_lower or "format" in error_lower:
            print(f"[FALLBACK] Format blocked, trying next...")
            for f in TEMP_DIR.glob(f"{video_id}_*"):
                try:
                    f.unlink()
                except:
                    pass
            continue
        
        # Other errors - record and stop
        record_video_failure(video_id, is_bot_error=False)
        return result
    
    # All formats failed
    record_video_failure(video_id, is_bot_error=False)
    return {
        "success": False,
        "error": "All formats failed",
        "video_id": video_id
    }


class YTDownloadHandler(BaseHTTPRequestHandler):
    """HTTP request handler for YouTube downloads."""
    
    api_key = DEFAULT_API_KEY
    
    def log_message(self, format, *args):
        print(f"[HTTP] {self.address_string()} - {format % args}")
    
    def send_json_response(self, data: dict, status: int = 200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())
    
    def send_error_response(self, message: str, status: int = 400, extra: dict = None):
        data = {"error": message, "success": False}
        if extra:
            data.update(extra)
        self.send_json_response(data, status)
    
    def check_auth(self) -> bool:
        api_key = self.headers.get("X-API-Key", "")
        if api_key != self.api_key:
            self.send_error_response("Invalid API key", 401)
            return False
        return True
    
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "X-API-Key, Content-Type")
        self.end_headers()
    
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)
        
        if path == "/health":
            # Include bot detection status
            now = time.time()
            in_cooldown = last_bot_detection > 0 and (now - last_bot_detection) < BOT_COOLDOWN[1]
            
            self.send_json_response({
                "status": "ok",
                "service": "yt-download-server",
                "version": "2.1.0",
                "cache_size": len(video_cache),
                "max_cache": MAX_CACHE_SIZE,
                "bot_cooldown": in_cooldown,
                "failed_videos": len(failed_videos)
            })
            return
        
        if not self.check_auth():
            return
        
        if path == "/download":
            self.handle_download(params)
        elif path == "/status":
            self.handle_status(params)
        elif path == "/cache":
            self.handle_cache_list()
        elif path == "/failed":
            self.handle_failed_list()
        elif path == "/active":
            with download_lock:
                self.send_json_response({
                    "success": True,
                    "active_downloads": list(active_downloads.keys())
                })
        else:
            self.send_error_response("Unknown endpoint", 404)
    
    def handle_failed_list(self):
        """List failed videos and their status."""
        with failed_lock:
            now = time.time()
            failed_info = []
            for video_id, info in failed_videos.items():
                wait_remaining = max(0, FAIL_MEMORY_TIME - (now - info["last_fail"]))
                failed_info.append({
                    "video_id": video_id,
                    "fail_count": info["count"],
                    "is_bot": info.get("is_bot", False),
                    "blocked": info["count"] >= MAX_FAILS_PER_VIDEO,
                    "wait_seconds": int(wait_remaining)
                })
        
        self.send_json_response({
            "success": True,
            "failed_videos": failed_info,
            "max_fails_allowed": MAX_FAILS_PER_VIDEO,
            "fail_memory_seconds": FAIL_MEMORY_TIME
        })
    
    def handle_cache_list(self):
        """List cached videos."""
        with cache_lock:
            cache_info = []
            for video_id, info in video_cache.items():
                cache_info.append({
                    "video_id": video_id,
                    "quality": info["quality"],
                    "size_mb": info["size"] / 1024 / 1024,
                    "cached_at": info["timestamp"]
                })
        
        self.send_json_response({
            "success": True,
            "cached_count": len(cache_info),
            "max_cache": MAX_CACHE_SIZE,
            "videos": cache_info
        })
    
    def handle_download(self, params: dict):
        """Handle download request."""
        video_id = params.get("video_id", [None])[0]
        quality = params.get("quality", ["1080"])[0]
        
        print(f"\n{'#'*60}")
        print(f"# DOWNLOAD REQUEST: {video_id}")
        print(f"# Quality: {quality}")
        print(f"# Client: {self.client_address}")
        print(f"{'#'*60}\n")
        
        if not video_id:
            self.send_error_response("Missing video_id")
            return
        
        if quality not in ["max", "1080", "720", "360"]:
            self.send_error_response("Invalid quality")
            return
        
        # Check cache first
        cached = get_from_cache(video_id)
        if cached:
            print(f"[CACHE] Serving from cache: {video_id}")
            self.stream_file(Path(cached["path"]), video_id, cached["quality"], from_cache=True)
            return
        
        # Check if video has failed too many times
        fail_status = check_video_fail_status(video_id)
        if fail_status["blocked"]:
            print(f"[BLOCKED] Video {video_id} blocked: {fail_status['reason']}")
            self.send_error_response(
                fail_status["reason"],
                429,  # Too Many Requests
                extra={
                    "retry_after": fail_status["wait_seconds"],
                    "fail_count": fail_status["fail_count"],
                    "blocked": True
                }
            )
            return
        
        # Check if already downloading
        with download_lock:
            if video_id in active_downloads:
                self.send_error_response("Download already in progress", 409)
                return
            active_downloads[video_id] = {
                "status": "queued",
                "progress": 0,
                "progress_text": "Na fila..."
            }
        
        try:
            # Apply rate limiting
            wait_for_rate_limit()
            
            # Download the video
            result = try_download_with_fallback(video_id, quality)
            
            if not result["success"]:
                error = result.get("error", "Download failed")
                
                # Determine appropriate status code
                if is_bot_error(error):
                    status = 503  # Service Unavailable
                elif "blocked" in error.lower() or "429" in error:
                    status = 429  # Too Many Requests
                else:
                    status = 500
                
                with download_lock:
                    active_downloads.pop(video_id, None)
                    
                self.send_error_response(error, status)
                return
            
            # Add to cache
            file_path = Path(result["path"])
            cache_path = add_to_cache(video_id, file_path, result["quality"])
            
            # Stream to client
            self.stream_file(cache_path, video_id, result["quality"], from_cache=False)
            
        except Exception as e:
            print(f"[ERROR] {e}")
            import traceback
            traceback.print_exc()
            try:
                self.send_error_response(str(e), 500)
            except:
                pass
        finally:
            with download_lock:
                active_downloads.pop(video_id, None)
            print(f"\n{'#'*60}")
            print(f"# COMPLETED: {video_id}")
            print(f"{'#'*60}\n")
    
    def stream_file(self, file_path: Path, video_id: str, quality: str, from_cache: bool = False):
        """Stream file to client."""
        file_size = file_path.stat().st_size
        filename = sanitize_filename(file_path.stem, for_http_header=True) + ".mp4"
        
        source = "CACHE" if from_cache else "DOWNLOAD"
        print(f"\n[STREAM] Starting transfer from {source}")
        print(f"[STREAM] File: {file_path.name}")
        print(f"[STREAM] Size: {file_size / 1024 / 1024:.1f} MB")
        
        with download_lock:
            active_downloads[video_id] = {
                "status": "transferring",
                "progress": 0,
                "progress_text": "A transferir...",
                "file_size": file_size
            }
        
        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(file_size))
        self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.send_header("X-Video-Id", video_id)
        self.send_header("X-Quality", quality)
        self.send_header("X-From-Cache", str(from_cache).lower())
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        
        chunk_size = 1024 * 1024
        bytes_sent = 0
        last_percent = 0
        start_time = time.time()
        
        try:
            with open(file_path, "rb") as f:
                while True:
                    chunk = f.read(chunk_size)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    bytes_sent += len(chunk)
                    
                    percent = int(bytes_sent / file_size * 100)
                    
                    with download_lock:
                        if video_id in active_downloads:
                            elapsed = time.time() - start_time
                            speed = bytes_sent / elapsed / 1024 / 1024 if elapsed > 0 else 0
                            active_downloads[video_id].update({
                                "progress": percent,
                                "progress_text": f"Transferindo: {percent}%"
                            })
                    
                    if percent >= last_percent + 10:
                        elapsed = time.time() - start_time
                        speed = bytes_sent / elapsed / 1024 / 1024 if elapsed > 0 else 0
                        print(f"[STREAM] {percent}% @ {speed:.1f} MB/s")
                        last_percent = percent
            
            elapsed = time.time() - start_time
            speed = bytes_sent / elapsed / 1024 / 1024 if elapsed > 0 else 0
            print(f"\n[STREAM] COMPLETE: {bytes_sent / 1024 / 1024:.1f} MB in {elapsed:.1f}s ({speed:.1f} MB/s)")
            
        except (BrokenPipeError, ConnectionResetError) as e:
            print(f"\n[STREAM] Client disconnected: {e}")
    
    def handle_status(self, params: dict):
        """Handle status request."""
        video_id = params.get("video_id", [None])[0]
        
        if video_id:
            with download_lock:
                status = active_downloads.get(video_id)
            
            # Check cache and fail status
            cached = get_from_cache(video_id) if not status else None
            fail_status = check_video_fail_status(video_id)
            
            response = {
                "success": True,
                "video_id": video_id,
                "cached": cached is not None,
            }
            
            if status:
                response["status"] = status
            elif cached:
                response["status"] = {"status": "cached", "quality": cached["quality"]}
            elif fail_status["blocked"]:
                response["status"] = {
                    "status": "blocked",
                    "reason": fail_status["reason"],
                    "retry_after": fail_status["wait_seconds"]
                }
            else:
                response["status"] = {"status": "not_found"}
                if fail_status["fail_count"] > 0:
                    response["previous_fails"] = fail_status["fail_count"]
            
            self.send_json_response(response)
        else:
            with download_lock:
                all_status = dict(active_downloads)
            self.send_json_response({
                "success": True,
                "downloads": all_status,
                "cache_size": len(video_cache),
                "failed_count": len(failed_videos)
            })


def get_local_ip():
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except:
        return "127.0.0.1"


def main():
    parser = argparse.ArgumentParser(description="YouTube Download Server")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--api-key", type=str, default=DEFAULT_API_KEY)
    args = parser.parse_args()
    
    # Check yt-dlp
    if not Path(YTDLP_PATH).exists() and not shutil.which("yt-dlp"):
        print("ERROR: yt-dlp not found")
        sys.exit(1)
    
    try:
        result = subprocess.run([YTDLP_PATH, "--version"], capture_output=True, text=True)
        print(f"Using yt-dlp: {result.stdout.strip()}")
    except:
        pass
    
    # Load cache
    load_cache_index()
    
    # Set API key
    YTDownloadHandler.api_key = args.api_key
    
    # Create directories
    DOWNLOADS_DIR.mkdir(parents=True, exist_ok=True)
    TEMP_DIR.mkdir(parents=True, exist_ok=True)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    
    local_ip = get_local_ip()
    
    print("=" * 60)
    print("  YouTube Download Server v2.1 (Anti-Bot)")
    print("=" * 60)
    print(f"  URL:          http://{local_ip}:{args.port}")
    print(f"  API Key:      {args.api_key}")
    print(f"  Cache:        {len(video_cache)}/{MAX_CACHE_SIZE} videos")
    print(f"  Cache Dir:    {CACHE_DIR}")
    print(f"  Cookies:      {'Yes - ' + COOKIES_FILE if COOKIES_FILE else 'No'}")
    print("=" * 60)
    print("\nAnti-Bot Settings:")
    print(f"  Normal Delay:     {NORMAL_DELAY[0]}-{NORMAL_DELAY[1]}s between downloads")
    print(f"  Bot Cooldown:     {BOT_COOLDOWN[0]}-{BOT_COOLDOWN[1]}s after detection")
    print(f"  Max Fails/Video:  {MAX_FAILS_PER_VIDEO} (blocks for {FAIL_MEMORY_TIME}s)")
    print("=" * 60)
    print("\nEndpoints:")
    print("  GET /health   - Health check")
    print("  GET /download - Download video")
    print("  GET /status   - Check status")
    print("  GET /cache    - List cached videos")
    print("  GET /failed   - List failed videos")
    print("=" * 60)
    print("\nWaiting for requests...\n")
    
    server = HTTPServer(("0.0.0.0", args.port), YTDownloadHandler)
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == "__main__":
    main()
