FROM python:3.13-slim AS client
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
ENTRYPOINT ["python", "client/play.py"]

FROM client AS client-rife
COPY requirements-rife.txt .
RUN pip install --no-cache-dir -r requirements-rife.txt
COPY client/art.py client/rife.py client/
RUN python -m client.rife
