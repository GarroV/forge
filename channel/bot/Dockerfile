# Тонкий образ, зависимости отдельным
# слоем, чтобы пересборка после правки кода не тянула их заново.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Не root: у процесса нет причин иметь права на образ.
RUN useradd --create-home --shell /usr/sbin/nologin app && chown -R app:app /app
USER app

CMD ["python", "main.py"]
