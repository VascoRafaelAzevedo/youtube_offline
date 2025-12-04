#!/usr/bin/env python3
"""
YouTube Download Server using yt-dlp
=====================================
A simple HTTP server that downloads YouTube videos using yt-dlp
and streams them back to the client (mobile app).

Authentication: Simple API key in header
Quality options: max, 1080, 720, 360

Usage:
    python server.py [--port PORT] [--api-key YOUR_KEY]
    
Example API call:
    curl -H "X-API-Key: your_secret_key" \
         "http://SERVER_IP:8765/download?video_id=dQw4w9WgXcQ&quality=1080"
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse
from pathlib import Path

# Configuration
DEFAULT_PORT = int(os.environ.get("PORT", 8765))
DEFAULT_API_KEY = os.environ.get("API_KEY", "offline_yt_secret_2025")

# Paths - support environment variables for Docker
DOWNLOADS_DIR = Path(os.environ.get("DOWNLOADS_DIR", str(Path.home() / "Downloads" / "OfflineYT_Server")))
TEMP_DIR = Path(os.environ.get("TEMP_DIR", str(Path(tempfile.gettempdir()) / "yt_server_temp")))

# Path to yt-dlp (use pip version which is more up-to-date)
YTDLP_PATH = os.environ.get("YTDLP_PATH", "")
if not YTDLP_PATH:
    local_path = Path.home() / ".local" / "bin" / "yt-dlp"
    YTDLP_PATH = str(local_path) if local_path.exists() else "yt-dlp"

# Track active downloads
active_downloads = {}
download_lock = threading.Lock()


def sanitize_filename(name: str, for_http_header: bool = False) -> str:
    """Remove invalid characters from filename.
    
    Args:
        name: The filename to sanitize
        for_http_header: If True, remove all non-ASCII characters for HTTP header compatibility
    """
    # Remove characters not allowed in filenames
    sanitized = re.sub(r'[<>:"/\\|?*]', '', name)
    
    # For HTTP headers, we need ASCII-only characters
    if for_http_header:
        # Replace common Unicode characters with ASCII equivalents
        sanitized = sanitized.replace('？', '').replace('：', '-').replace('！', '!')
        # Remove any remaining non-ASCII characters
        sanitized = sanitized.encode('ascii', 'ignore').decode('ascii')
    
    # Replace multiple spaces with single space
    sanitized = re.sub(r'\s+', ' ', sanitized).strip()
    # Limit length
    if len(sanitized) > 100:
        sanitized = sanitized[:100]
    return sanitized if sanitized else "video"


def get_quality_formats(quality: str) -> list:
    """Get list of yt-dlp format strings to try, in order of preference.
    
    YouTube now uses SABR streaming which blocks many formats.
    We try multiple formats, falling back to lower quality if blocked.
    Prefer 60fps when available.
    """
    # List of formats to try in order (from highest to lowest quality)
    # Prefer 60fps versions first, then fall back to any fps
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
    
    # Determine starting point based on requested quality
    start_index = {
        "max": 0,   # Start from 4K60
        "1080": 2,  # Start from 1080p60
        "720": 4,   # Start from 720p60
        "360": 7,   # Start from 360p
    }.get(quality, 2)
    
    return all_formats[start_index:]


def try_download_with_fallback(video_id: str, quality: str = "1080") -> dict:
    """
    Try to download a video, falling back to lower qualities if blocked.
    """
    formats_to_try = get_quality_formats(quality)
    
    for i, (quality_name, format_string) in enumerate(formats_to_try):
        print(f"\n[FALLBACK] Trying format {i+1}/{len(formats_to_try)}: {quality_name}")
        
        result = download_video(video_id, format_string, quality_name)
        
        if result["success"]:
            return result
        
        # Check if it's a 403 error (format blocked)
        error = result.get("error", "").lower()
        if "403" in error or "forbidden" in error or "format" in error:
            print(f"[FALLBACK] Format {quality_name} blocked, trying next...")
            # Clean up any partial files
            for f in TEMP_DIR.glob(f"{video_id}_*"):
                try:
                    f.unlink()
                except:
                    pass
            continue
        else:
            # Other error, don't retry
            print(f"[FALLBACK] Non-recoverable error: {error}")
            return result
    
    return {
        "success": False,
        "error": "All quality formats failed - video may be protected",
        "video_id": video_id
    }


def download_video(video_id: str, format_string: str, quality_name: str) -> dict:
    """
    Download a YouTube video using yt-dlp with real-time progress.
    Returns dict with status, path, and info.
    
    Args:
        video_id: YouTube video ID
        format_string: yt-dlp format string
        quality_name: Human-readable quality name for logging
    """
    url = f"https://www.youtube.com/watch?v={video_id}"
    
    # Create temp directory for this download
    TEMP_DIR.mkdir(parents=True, exist_ok=True)
    DOWNLOADS_DIR.mkdir(parents=True, exist_ok=True)
    
    output_template = str(TEMP_DIR / f"{video_id}_%(title)s.%(ext)s")
    
    # yt-dlp command with options to bypass restrictions
    cmd = [
        YTDLP_PATH,
        "-f", format_string,
        "--merge-output-format", "mp4",
        "-o", output_template,
        "--no-playlist",
        "--newline",           # Each progress line on new line
        "--no-continue",       # Don't resume partial downloads (avoids 403 on resume)
        "--no-part",           # Don't use .part files
        "--retries", "3",      # Fewer retries per format (we'll try other formats)
        "--fragment-retries", "3",
        # Progress template
        "--progress-template", "download:%(progress._percent_str)s of %(progress._total_bytes_str)s at %(progress._speed_str)s ETA %(progress._eta_str)s",
        url
    ]
    
    print(f"\n{'='*60}")
    print(f"[DOWNLOAD] Starting download: {video_id}")
    print(f"[DOWNLOAD] Quality: {quality_name}")
    print(f"[DOWNLOAD] Format: {format_string}")
    print(f"[DOWNLOAD] URL: {url}")
    print(f"{'='*60}")
    
    # Update active_downloads with initial status
    with download_lock:
        active_downloads[video_id] = {
            "status": "starting",
            "phase": "yt-dlp",
            "progress": 0,
            "progress_text": "A iniciar...",
            "started": time.time()
        }
    
    try:
        # Run yt-dlp with real-time output
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,  # Line buffered
            universal_newlines=True
        )
        
        last_progress = ""
        error_output = []
        current_percent = 0
        
        # Read output line by line
        for line in process.stdout:
            line = line.strip()
            if not line:
                continue
            
            # Check for progress updates (contains %)
            if '%' in line and ('of' in line or 'ETA' in line):
                # Parse percentage
                try:
                    percent_str = line.split('%')[0].strip().split()[-1]
                    current_percent = float(percent_str)
                except:
                    pass
                
                # Update active_downloads with progress
                with download_lock:
                    if video_id in active_downloads:
                        active_downloads[video_id].update({
                            "status": "downloading",
                            "phase": "yt-dlp",
                            "progress": current_percent,
                            "progress_text": f"YouTube: {line}"
                        })
                
                # Clear previous line and print progress
                if last_progress:
                    print(f"\r[PROGRESS] {line}" + " " * 20, end="", flush=True)
                else:
                    print(f"[PROGRESS] {line}", end="", flush=True)
                last_progress = line
            elif 'Downloading' in line or 'Merging' in line:
                if last_progress:
                    print()  # New line after progress
                print(f"[STATUS] {line}")
                last_progress = ""
                
                # Update status for merging
                if 'Merging' in line:
                    with download_lock:
                        if video_id in active_downloads:
                            active_downloads[video_id].update({
                                "status": "merging",
                                "phase": "merge",
                                "progress": 100,
                                "progress_text": "A juntar vídeo e áudio..."
                            })
            elif 'error' in line.lower() or 'ERROR' in line:
                print(f"\n[ERROR] {line}")
                error_output.append(line)
            elif 'Destination' in line:
                print(f"\n[FILE] {line}")
            elif line.startswith('['):
                print(f"[YT-DLP] {line}")
        
        if last_progress:
            print()  # Final newline after progress
        
        # Wait for process to complete
        return_code = process.wait(timeout=600)
        
        if return_code != 0:
            error_msg = "\n".join(error_output) if error_output else f"yt-dlp exited with code {return_code}"
            print(f"[DOWNLOAD] FAILED: {error_msg}")
            with download_lock:
                if video_id in active_downloads:
                    active_downloads[video_id].update({
                        "status": "failed",
                        "error": error_msg
                    })
            return {
                "success": False,
                "error": error_msg,
                "video_id": video_id
            }
        
        # Find the output file
        print(f"[DOWNLOAD] Looking for output file...")
        output_files = list(TEMP_DIR.glob(f"{video_id}_*.mp4"))
        
        if not output_files:
            # Try any mp4 file that was just created
            all_mp4 = list(TEMP_DIR.glob("*.mp4"))
            output_files = [f for f in all_mp4 if video_id in f.name]
            
            if not output_files:
                # Get most recently modified mp4
                output_files = sorted(all_mp4, key=lambda f: f.stat().st_mtime, reverse=True)
                if output_files and (time.time() - output_files[0].stat().st_mtime) < 120:
                    output_files = [output_files[0]]
                else:
                    output_files = []
        
        if not output_files:
            print(f"[DOWNLOAD] ERROR: Output file not found!")
            print(f"[DOWNLOAD] Files in temp dir: {list(TEMP_DIR.glob('*'))}")
            return {
                "success": False,
                "error": "Output file not found after download",
                "video_id": video_id
            }
        
        output_file = output_files[0]
        file_size = output_file.stat().st_size
        
        # Update status to ready for transfer
        with download_lock:
            if video_id in active_downloads:
                active_downloads[video_id].update({
                    "status": "ready",
                    "phase": "transfer",
                    "progress": 0,
                    "progress_text": "Pronto para transferir",
                    "file_size": file_size
                })
        
        print(f"{'='*60}")
        print(f"[DOWNLOAD] SUCCESS!")
        print(f"[DOWNLOAD] File: {output_file.name}")
        print(f"[DOWNLOAD] Size: {file_size / 1024 / 1024:.1f} MB")
        print(f"[DOWNLOAD] Quality: {quality_name}")
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
        print(f"[DOWNLOAD] TIMEOUT: Download took more than 10 minutes")
        process.kill()
        return {
            "success": False,
            "error": "Download timed out (10 minutes)",
            "video_id": video_id
        }
    except Exception as e:
        print(f"[DOWNLOAD] EXCEPTION: {e}")
        import traceback
        traceback.print_exc()
        return {
            "success": False,
            "error": str(e),
            "video_id": video_id
        }


class YTDownloadHandler(BaseHTTPRequestHandler):
    """HTTP request handler for YouTube downloads."""
    
    api_key = DEFAULT_API_KEY
    
    def log_message(self, format, *args):
        """Custom log format."""
        print(f"[HTTP] {self.address_string()} - {format % args}")
    
    def send_json_response(self, data: dict, status: int = 200):
        """Send JSON response."""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())
    
    def send_error_response(self, message: str, status: int = 400):
        """Send error response."""
        self.send_json_response({"error": message, "success": False}, status)
    
    def check_auth(self) -> bool:
        """Check API key authentication."""
        api_key = self.headers.get("X-API-Key", "")
        if api_key != self.api_key:
            self.send_error_response("Invalid API key", 401)
            return False
        return True
    
    def do_OPTIONS(self):
        """Handle CORS preflight."""
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "X-API-Key, Content-Type")
        self.end_headers()
    
    def do_GET(self):
        """Handle GET requests."""
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)
        
        # Health check (no auth needed)
        if path == "/health":
            self.send_json_response({
                "status": "ok",
                "service": "yt-download-server",
                "version": "1.0.0"
            })
            return
        
        # All other endpoints require auth
        if not self.check_auth():
            return
        
        # Download endpoint - initiates download and streams file back
        if path == "/download":
            self.handle_download(params)
            return
        
        # Status endpoint - check download progress
        if path == "/status":
            self.handle_status(params)
            return
        
        # List active downloads
        if path == "/active":
            with download_lock:
                self.send_json_response({
                    "success": True,
                    "active_downloads": list(active_downloads.keys())
                })
            return
        
        # Unknown endpoint
        self.send_error_response("Unknown endpoint", 404)
    
    def handle_download(self, params: dict):
        """Handle download request - download video and stream it back."""
        video_id = params.get("video_id", [None])[0]
        quality = params.get("quality", ["1080"])[0]
        
        print(f"\n{'#'*60}")
        print(f"# NEW DOWNLOAD REQUEST")
        print(f"# Video ID: {video_id}")
        print(f"# Quality: {quality}")
        print(f"# Client: {self.client_address}")
        print(f"{'#'*60}\n")
        
        if not video_id:
            print("[REQUEST] ERROR: Missing video_id")
            self.send_error_response("Missing video_id parameter")
            return
        
        # Validate quality
        if quality not in ["max", "1080", "720", "360"]:
            print(f"[REQUEST] ERROR: Invalid quality '{quality}'")
            self.send_error_response("Invalid quality. Use: max, 1080, 720, 360")
            return
        
        # Check if already downloading
        with download_lock:
            if video_id in active_downloads:
                print(f"[REQUEST] ERROR: Already downloading {video_id}")
                self.send_error_response("Download already in progress", 409)
                return
            active_downloads[video_id] = {
                "status": "starting", 
                "phase": "init",
                "started": time.time(),
                "progress": 0,
                "progress_text": "A iniciar..."
            }
        
        try:
            # Download the video with automatic fallback to lower qualities
            print(f"[REQUEST] Starting download with fallback...")
            result = try_download_with_fallback(video_id, quality)
            
            if not result["success"]:
                with download_lock:
                    active_downloads.pop(video_id, None)
                print(f"[REQUEST] Download failed: {result.get('error')}")
                self.send_error_response(result.get("error", "Download failed"), 500)
                return
            
            # Stream the file back to client
            file_path = Path(result["path"])
            file_size = result["size"]
            # Use ASCII-safe filename for HTTP header
            filename = sanitize_filename(file_path.stem, for_http_header=True) + ".mp4"
            
            print(f"\n[STREAM] Starting file transfer to client...")
            print(f"[STREAM] File: {file_path.name}")
            print(f"[STREAM] Size: {file_size / 1024 / 1024:.1f} MB")
            
            # Update status to transferring
            with download_lock:
                if video_id in active_downloads:
                    active_downloads[video_id].update({
                        "status": "transferring",
                        "phase": "transfer",
                        "progress": 0,
                        "progress_text": "A transferir para dispositivo...",
                        "file_size": file_size
                    })
            
            self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(file_size))
            self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
            self.send_header("X-Video-Id", video_id)
            self.send_header("X-Quality", quality)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            
            # Stream file in chunks with progress
            chunk_size = 1024 * 1024  # 1MB chunks
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
                        
                        # Calculate progress
                        percent = int(bytes_sent / file_size * 100)
                        
                        # Update active_downloads with transfer progress
                        with download_lock:
                            if video_id in active_downloads:
                                elapsed = time.time() - start_time
                                speed = bytes_sent / elapsed / 1024 / 1024 if elapsed > 0 else 0
                                active_downloads[video_id].update({
                                    "status": "transferring",
                                    "phase": "transfer",
                                    "progress": percent,
                                    "progress_text": f"Transferindo: {percent}% ({speed:.1f} MB/s)",
                                    "bytes_sent": bytes_sent,
                                    "file_size": file_size
                                })
                        
                        # Show progress every 10%
                        if percent >= last_percent + 10:
                            elapsed = time.time() - start_time
                            speed = bytes_sent / elapsed / 1024 / 1024 if elapsed > 0 else 0
                            print(f"[STREAM] {percent}% ({bytes_sent / 1024 / 1024:.1f}/{file_size / 1024 / 1024:.1f} MB) @ {speed:.1f} MB/s")
                            last_percent = percent
                
                elapsed = time.time() - start_time
                speed = bytes_sent / elapsed / 1024 / 1024 if elapsed > 0 else 0
                print(f"\n[STREAM] COMPLETE!")
                print(f"[STREAM] Sent: {bytes_sent / 1024 / 1024:.1f} MB in {elapsed:.1f}s ({speed:.1f} MB/s)")
                
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError) as e:
                elapsed = time.time() - start_time
                print(f"\n[STREAM] CLIENT DISCONNECTED!")
                print(f"[STREAM] Sent {bytes_sent / 1024 / 1024:.1f} of {file_size / 1024 / 1024:.1f} MB ({int(bytes_sent/file_size*100)}%)")
                print(f"[STREAM] Error: {e}")
            except Exception as e:
                print(f"\n[STREAM] ERROR: {e}")
                import traceback
                traceback.print_exc()
            
            # Cleanup temp file after sending
            try:
                file_path.unlink()
                print(f"[CLEANUP] Deleted temp file")
            except Exception as e:
                print(f"[CLEANUP] Failed to delete temp file: {e}")
            
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError) as e:
            print(f"[ERROR] Client disconnected during request: {e}")
        except Exception as e:
            print(f"[ERROR] Unexpected error: {e}")
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
            print(f"# REQUEST COMPLETED: {video_id}")
            print(f"{'#'*60}\n")
    
    def handle_status(self, params: dict):
        """Handle status check request."""
        video_id = params.get("video_id", [None])[0]
        
        if video_id:
            with download_lock:
                status = active_downloads.get(video_id)
            
            if status:
                self.send_json_response({
                    "success": True,
                    "video_id": video_id,
                    "status": status
                })
            else:
                self.send_json_response({
                    "success": True,
                    "video_id": video_id,
                    "status": "not_found"
                })
        else:
            with download_lock:
                all_status = dict(active_downloads)
            self.send_json_response({
                "success": True,
                "downloads": all_status
            })


def get_local_ip():
    """Get local IP address for display."""
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
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                       help=f"Port to listen on (default: {DEFAULT_PORT})")
    parser.add_argument("--api-key", type=str, default=DEFAULT_API_KEY,
                       help="API key for authentication")
    args = parser.parse_args()
    
    # Check yt-dlp is installed
    if not Path(YTDLP_PATH).exists() and not shutil.which("yt-dlp"):
        print("ERROR: yt-dlp not found. Install with: pip install --break-system-packages yt-dlp")
        sys.exit(1)
    
    # Show which yt-dlp we're using
    try:
        result = subprocess.run([YTDLP_PATH, "--version"], capture_output=True, text=True)
        yt_version = result.stdout.strip()
        print(f"Using yt-dlp version: {yt_version} ({YTDLP_PATH})")
    except:
        pass
    
    # Check ffmpeg is installed (needed for merging)
    if not shutil.which("ffmpeg"):
        print("WARNING: ffmpeg not found. Some videos may not merge properly.")
    
    # Set API key
    YTDownloadHandler.api_key = args.api_key
    
    # Create directories
    DOWNLOADS_DIR.mkdir(parents=True, exist_ok=True)
    TEMP_DIR.mkdir(parents=True, exist_ok=True)
    
    local_ip = get_local_ip()
    
    print("=" * 60)
    print("  YouTube Download Server (yt-dlp)")
    print("=" * 60)
    print(f"  Local URL:    http://127.0.0.1:{args.port}")
    print(f"  Network URL:  http://{local_ip}:{args.port}")
    print(f"  API Key:      {args.api_key}")
    print(f"  Temp Dir:     {TEMP_DIR}")
    print("=" * 60)
    print("\nEndpoints:")
    print(f"  GET /health              - Health check (no auth)")
    print(f"  GET /download            - Download video (requires X-API-Key header)")
    print(f"      ?video_id=VIDEO_ID   - YouTube video ID")
    print(f"      &quality=1080        - Quality: max, 1080, 720, 360")
    print(f"  GET /status              - Check download status")
    print(f"  GET /active              - List active downloads")
    print("=" * 60)
    print("\nExample curl:")
    print(f'  curl -H "X-API-Key: {args.api_key}" \\')
    print(f'       "http://{local_ip}:{args.port}/download?video_id=dQw4w9WgXcQ&quality=1080" \\')
    print(f'       -o video.mp4')
    print("=" * 60)
    print("\nWaiting for requests... (Ctrl+C to stop)\n")
    
    # Start server
    server = HTTPServer(("0.0.0.0", args.port), YTDownloadHandler)
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n\nShutting down server...")
        server.shutdown()
        
        # Cleanup temp files
        if TEMP_DIR.exists():
            for f in TEMP_DIR.glob("*"):
                try:
                    f.unlink()
                except:
                    pass
        
        print("Server stopped.")


if __name__ == "__main__":
    main()
