#!/usr/bin/env python3
"""
YouTube Download Server
Uses yt-dlp to download videos in 1080p quality
The Flutter app connects to this server to request downloads
"""

import os
import sys
import json
import subprocess
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import socket

# Configuration
PORT = 8765
DOWNLOAD_DIR = os.path.expanduser("~/Downloads/OfflineYT")

# Ensure download directory exists
os.makedirs(DOWNLOAD_DIR, exist_ok=True)

# Track active downloads
downloads = {}
downloads_lock = threading.Lock()


def get_local_ip():
    """Get the local IP address"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except:
        return "127.0.0.1"


def download_video(video_id: str, title: str):
    """Download a video using yt-dlp"""
    try:
        with downloads_lock:
            downloads[video_id] = {
                "status": "downloading",
                "progress": 0,
                "title": title,
                "file_path": None,
                "error": None
            }
        
        # Sanitize title for filename
        safe_title = "".join(c for c in title if c.isalnum() or c in " -_").strip()[:100]
        if not safe_title:
            safe_title = video_id
        
        output_path = os.path.join(DOWNLOAD_DIR, f"{safe_title}.mp4")
        
        # yt-dlp command for 1080p with audio merged
        cmd = [
            "yt-dlp",
            "-f", "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=1080]+bestaudio/best[height<=1080]",
            "--merge-output-format", "mp4",
            "-o", output_path,
            "--progress",
            "--newline",
            f"https://www.youtube.com/watch?v={video_id}"
        ]
        
        print(f"[yt-dlp] Starting download: {video_id}")
        print(f"[yt-dlp] Command: {' '.join(cmd)}")
        
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1
        )
        
        # Parse progress from yt-dlp output
        for line in process.stdout:
            line = line.strip()
            if line:
                print(f"[yt-dlp] {line}")
                
                # Parse progress percentage
                if "[download]" in line and "%" in line:
                    try:
                        # Extract percentage like "50.0%"
                        parts = line.split()
                        for part in parts:
                            if "%" in part:
                                pct = float(part.replace("%", ""))
                                with downloads_lock:
                                    if video_id in downloads:
                                        downloads[video_id]["progress"] = pct / 100.0
                                break
                    except:
                        pass
        
        process.wait()
        
        if process.returncode == 0 and os.path.exists(output_path):
            file_size = os.path.getsize(output_path)
            print(f"[yt-dlp] Download complete: {output_path} ({file_size / 1024 / 1024:.1f} MB)")
            with downloads_lock:
                downloads[video_id] = {
                    "status": "completed",
                    "progress": 1.0,
                    "title": title,
                    "file_path": output_path,
                    "file_size": file_size,
                    "error": None
                }
        else:
            print(f"[yt-dlp] Download failed: return code {process.returncode}")
            with downloads_lock:
                downloads[video_id] = {
                    "status": "failed",
                    "progress": 0,
                    "title": title,
                    "file_path": None,
                    "error": f"yt-dlp returned code {process.returncode}"
                }
    
    except Exception as e:
        print(f"[yt-dlp] Error: {e}")
        with downloads_lock:
            downloads[video_id] = {
                "status": "failed",
                "progress": 0,
                "title": title,
                "file_path": None,
                "error": str(e)
            }


class DownloadHandler(BaseHTTPRequestHandler):
    """HTTP handler for download requests"""
    
    def log_message(self, format, *args):
        print(f"[HTTP] {args[0]}")
    
    def send_json(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())
    
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
    
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)
        
        if path == "/":
            # Health check
            self.send_json({
                "status": "ok",
                "server": "yt-dlp-server",
                "download_dir": DOWNLOAD_DIR
            })
        
        elif path == "/download":
            # Start a download
            video_id = query.get("id", [None])[0]
            title = query.get("title", [video_id])[0]
            
            if not video_id:
                self.send_json({"error": "Missing video id"}, 400)
                return
            
            # Check if already downloading or completed
            with downloads_lock:
                if video_id in downloads:
                    status = downloads[video_id]["status"]
                    if status == "downloading":
                        self.send_json({"message": "Already downloading", "status": downloads[video_id]})
                        return
                    elif status == "completed":
                        self.send_json({"message": "Already completed", "status": downloads[video_id]})
                        return
            
            # Start download in background thread
            thread = threading.Thread(target=download_video, args=(video_id, title))
            thread.daemon = True
            thread.start()
            
            self.send_json({"message": "Download started", "video_id": video_id})
        
        elif path == "/status":
            # Get status of a download
            video_id = query.get("id", [None])[0]
            
            if video_id:
                with downloads_lock:
                    if video_id in downloads:
                        self.send_json(downloads[video_id])
                    else:
                        self.send_json({"status": "not_found"}, 404)
            else:
                # Return all downloads
                with downloads_lock:
                    self.send_json(downloads)
        
        elif path == "/list":
            # List downloaded files
            files = []
            if os.path.exists(DOWNLOAD_DIR):
                for f in os.listdir(DOWNLOAD_DIR):
                    if f.endswith(".mp4"):
                        path = os.path.join(DOWNLOAD_DIR, f)
                        files.append({
                            "name": f,
                            "path": path,
                            "size": os.path.getsize(path)
                        })
            self.send_json({"files": files})
        
        else:
            self.send_json({"error": "Not found"}, 404)


def main():
    local_ip = get_local_ip()
    
    print("=" * 60)
    print("  YouTube Download Server (yt-dlp)")
    print("=" * 60)
    print(f"  Download directory: {DOWNLOAD_DIR}")
    print(f"  Server URL: http://{local_ip}:{PORT}")
    print("=" * 60)
    print()
    print("Endpoints:")
    print(f"  GET /                - Health check")
    print(f"  GET /download?id=XXX&title=YYY - Start download")
    print(f"  GET /status?id=XXX   - Get download status")
    print(f"  GET /status          - Get all downloads")
    print(f"  GET /list            - List downloaded files")
    print()
    print("Use this URL in the Flutter app!")
    print()
    
    server = HTTPServer(("0.0.0.0", PORT), DownloadHandler)
    print(f"Server running on http://0.0.0.0:{PORT}")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == "__main__":
    main()
