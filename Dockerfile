FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    gcc \
    g++ \
    libffi-dev \
    libssl-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

# install poetry
RUN curl -sSL https://install.python-poetry.org | python3 -
ENV PATH="/root/.local/bin:$PATH"

# copy lockfile first — layer caches until deps change
COPY pyproject.toml poetry.lock* ./
RUN poetry install --no-root --no-interaction

COPY . .

CMD ["poetry", "run", "jupyter", "lab", \
    "--ip=0.0.0.0", "--no-browser", "--allow-root"]