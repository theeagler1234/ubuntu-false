FROM python:3.12-alpine

RUN pip install --no-cache-dir aiohttp==3.10.10

WORKDIR /app
COPY gate.py .

EXPOSE 3000
USER nobody
CMD ["python", "-u", "gate.py"]
