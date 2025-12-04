# YouTube Download Server
# =======================

A simple Python HTTP server that uses yt-dlp to download YouTube videos
and stream them to your mobile app.

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

# Both
python server.py --port 9000 --api-key "my_super_secret_key_123"
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
```

## Quality Options

| Quality | Description |
|---------|-------------|
| `max`   | Best available quality (could be 4K) |
| `1080`  | Up to 1080p Full HD |
| `720`   | Up to 720p HD |
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
# Set your API key (optional, uses default if not set)
export API_KEY="your_secret_api_key"

# Build and run
docker-compose up -d

# Check logs
docker-compose logs -f

# Stop
docker-compose down
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
  offline-youtube-server

# Check logs
docker logs -f yt-server
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 8765 | Server port |
| `API_KEY` | offline_yt_secret_2025 | Authentication key |
| `DOWNLOADS_DIR` | /downloads | Directory for downloaded videos |
| `TEMP_DIR` | /tmp/yt_server_temp | Temporary processing directory |

### Docker Health Check

The container includes a health check endpoint at `/health`. Docker will automatically monitor the service and restart it if it becomes unhealthy.

```bash
# Check container health
docker inspect --format='{{.State.Health.Status}}' yt-server
```

## Troubleshooting

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
