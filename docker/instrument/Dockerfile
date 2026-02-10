FROM python:3.12-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        curl \
        wget \
        ca-certificates \
        atomicparsley && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    yt-dlp==2026.2.4 \
    fastapi==0.128.5 \
    uvicorn==0.40.0

COPY app.py /app.py

WORKDIR /data

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

CMD ["uvicorn", "app:app", "--app-dir", "/", "--host", "0.0.0.0", "--port", "8000"]
