# Image for Santa Bobot (https://github.com/mishgun64/Santa_Bobot)
#
# Differences from the upstream "dockerfile":
#   1. dependencies are installed into site-packages (upstream installs them to
#      /app/pip without PYTHONPATH, so "import telebot" fails);
#   2. only main.py is baked into the image - data/ (users.json, secrets.json)
#      is provided by the volume ./santa_bot/data:/app/data, so the bot token
#      never ends up in an image layer;
#   3. /data is a symlink to /app/data, because main.py reads the database from
#      the absolute path /data/db.json while the volume is mounted to /app/data.

FROM python:3.11.10-slim-bookworm

WORKDIR /app

# pyTelegramBotAPI from requirements.txt (the file itself is UTF-16 encoded)
RUN pip install --no-cache-dir pyTelegramBotAPI==4.29.1

COPY main.py ./

RUN mkdir -p /app/data && ln -s /app/data /data

ENV PYTHONUNBUFFERED=1
ENV TZ=Europe/Moscow

ENTRYPOINT ["python3", "/app/main.py"]
