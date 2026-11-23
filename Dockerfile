FROM python:3.13-slim AS client
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
ENTRYPOINT ["python", "examples/terminal/play.py"]

FROM client AS client-rife
COPY requirements-rife.txt .
RUN pip install --no-cache-dir -r requirements-rife.txt
COPY examples/terminal/art.py examples/terminal/rife.py examples/terminal/
RUN python -m examples.terminal.rife
