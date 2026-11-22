# ---- build stage: validates the source; keeps the pattern ready for dependencies later
FROM python:3.12.16-slim-bookworm AS build
WORKDIR /src
COPY app.py .
RUN python -m py_compile app.py

# ---- runtime stage
FROM python:3.12.16-slim-bookworm
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080
WORKDIR /app
COPY --from=build /src/app.py .
# Numeric UID on purpose: Kubernetes runAsNonRoot cannot verify a named user.
USER 10001:10001
EXPOSE 8080
CMD ["python", "app.py"]
