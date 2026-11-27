FROM python:3.11-slim-bookworm

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONIOENCODING=utf-8

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY core.py send.py ./
RUN mkdir -p /app/data

# 配置文件放在 /app/data/config.json（由 docker-compose 挂载 ./data 进来）
CMD ["python", "core.py"]
