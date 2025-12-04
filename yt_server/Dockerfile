FROM python:3.12-slim

# Install system dependencies for yt-dlp
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m -s /bin/bash ytserver

# Set working directory
WORKDIR /app

# Copy requirements first for caching
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy server code
COPY server.py .

# Create directories for downloads and temp
RUN mkdir -p /downloads /tmp/yt_server_temp \
    && chown -R ytserver:ytserver /downloads /tmp/yt_server_temp /app

# Switch to non-root user
USER ytserver

# Environment variables
ENV PORT=8765
ENV API_KEY=change_me_in_production
ENV DOWNLOADS_DIR=/downloads
ENV TEMP_DIR=/tmp/yt_server_temp

# Expose port
EXPOSE 8765

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:${PORT}/health')" || exit 1

# Run server
CMD ["python", "server.py"]
