# YouTube Download Server
# =======================

A Python HTTP server that uses yt-dlp to download YouTube videos
and stream them to your mobile app. Features include smart caching,
sequential download queue, and anti-bot detection measures.

## Features

- **Smart Caching**: Keeps last 50 videos in cache (configurable)
- **Sequential Queue**: Downloads one video at a time to avoid rate limiting
- **Anti-Bot Measures**: Random delays between downloads (5-10s)
- **Cookie Support**: Optional browser cookies for authentication
- **60fps Support**: Downloads best available quality including high frame rates
- **Docker Ready**: Easy deployment with Docker Compose

## Requirements

- Python 3.8+
- yt-dlp
- ffmpeg (for merging video+audio)

## Installation

```bash
# Install yt-dlp
pip install yt-dlp

# Or with apt
sudo apt install yt-dlp

# Install ffmpeg if not already installed
sudo apt install ffmpeg
```

## Usage

```bash
# Start with default settings (port 8765, default API key)
python server.py

# Custom port
python server.py --port 9000

# Custom API key (RECOMMENDED for security)
python server.py --api-key "my_super_secret_key_123"

# With cookies file (for bypassing bot detection)
python server.py --api-key "my_key" --cookies /path/to/cookies.txt

# All options
python server.py --port 9000 --api-key "my_key" --cookies cookies.txt --cache-size 100
```

### Exporting Browser Cookies

If you're getting "Sign in to confirm you're not a bot" errors, export cookies from your browser:

```bash
# Export cookies using yt-dlp
yt-dlp --cookies-from-browser chrome --cookies cookies.txt "https://youtube.com"

# Or for Firefox
yt-dlp --cookies-from-browser firefox --cookies cookies.txt "https://youtube.com"
```

## API Endpoints

### Health Check (no auth required)
```
GET /health
```

### Download Video (requires X-API-Key header)
```
GET /download?video_id=VIDEO_ID&quality=QUALITY

Parameters:
- video_id: YouTube video ID (e.g., "dQw4w9WgXcQ")
- quality: max | 1080 | 720 | 360

Response: Binary MP4 file stream
```

### Check Status
```
GET /status?video_id=VIDEO_ID

Response:
- queued: Video is in download queue
- downloading: Currently being downloaded
- cached: Video is in cache, ready to stream
- not_found: Video not in system
```

### Queue Info
```
GET /queue

Returns current queue status and cache contents
```

### List Active Downloads
```
GET /active
```

## Example Usage

```bash
# Health check
curl http://localhost:8765/health

# Download a video in 1080p
curl -H "X-API-Key: offline_yt_secret_2025" \
     "http://localhost:8765/download?video_id=dQw4w9WgXcQ&quality=1080" \
     -o video.mp4

# Download in max quality
curl -H "X-API-Key: offline_yt_secret_2025" \
     "http://localhost:8765/download?video_id=dQw4w9WgXcQ&quality=max" \
     -o video.mp4

# Check queue status
curl -H "X-API-Key: offline_yt_secret_2025" \
     "http://localhost:8765/queue"
```

## Quality Options

| Quality | Description |
|---------|-------------|
| `max`   | Best available quality (could be 4K @ 60fps) |
| `1080`  | Up to 1080p @ 60fps Full HD |
| `720`   | Up to 720p @ 60fps HD |
| `360`   | Up to 360p (low quality, small files) |

## Security

The server uses a simple API key authentication. Set your own key with:

```bash
python server.py --api-key "YOUR_SECRET_KEY"
```

Update the same key in your Flutter app's configuration.

## Running as a Service (Linux)

Create a systemd service:

```bash
sudo nano /etc/systemd/system/yt-download-server.service
```

```ini
[Unit]
Description=YouTube Download Server
After=network.target

[Service]
Type=simple
User=YOUR_USERNAME
WorkingDirectory=/path/to/yt_server
ExecStart=/usr/bin/python3 /path/to/yt_server/server.py --api-key "YOUR_SECRET_KEY"
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable yt-download-server
sudo systemctl start yt-download-server
```

## Docker Deployment

### Quick Start with Docker Compose

```bash
# Copy and configure environment
cp .env.example .env
nano .env  # Set your API_KEY

# Build and run
docker-compose up -d

# Check logs
docker-compose logs -f

# Stop
docker-compose down
```

### Using Cookies with Docker

1. Export cookies from your browser (see above)
2. Place `cookies.txt` in the `yt_server` directory
3. Update `docker-compose.yml` to mount it:

```yaml
volumes:
  - yt_downloads:/downloads
  - ./cookies.txt:/cookies/cookies.txt:ro
environment:
  - COOKIES_FILE=/cookies/cookies.txt
```

### Manual Docker Build

```bash
# Build the image
docker build -t offline-youtube-server .

# Run the container
docker run -d \
  --name yt-server \
  -p 8765:8765 \
  -e API_KEY="your_secret_key" \
  -v yt_downloads:/downloads \
  -v yt_cache:/cache \
  offline-youtube-server

# Check logs
docker logs -f yt-server
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 8765 | Server port |
| `API_KEY` | offline_yt_secret_2025 | Authentication key |
| `MAX_CACHE_SIZE` | 50 | Number of videos to keep in cache |
| `DOWNLOADS_DIR` | /downloads | Directory for downloaded videos |
| `CACHE_DIR` | /cache | Directory for cached videos |
| `TEMP_DIR` | /tmp/yt_server_temp | Temporary processing directory |
| `COOKIES_FILE` | (none) | Path to browser cookies file |

### Docker Health Check

The container includes a health check endpoint at `/health`. Docker will automatically monitor the service and restart it if it becomes unhealthy.

```bash
# Check container health
docker inspect --format='{{.State.Health.Status}}' yt-server
```

## Troubleshooting

### "Sign in to confirm you're not a bot"
This means YouTube is rate limiting you. Solutions:
1. Export browser cookies (see above)
2. Wait a few hours before trying again
3. Use a different IP/VPN

### "yt-dlp not found"
```bash
pip install yt-dlp
# or
sudo apt install yt-dlp
```

### "ffmpeg not found"
```bash
sudo apt install ffmpeg
```

### Videos not merging properly
Make sure ffmpeg is installed and in your PATH.

### Connection refused
- Check firewall settings
- Make sure the port is open: `sudo ufw allow 8765`

### Downloads timing out
The new queue system processes one video at a time. If you see a video stuck in "queued" status, check the server logs for errors.

