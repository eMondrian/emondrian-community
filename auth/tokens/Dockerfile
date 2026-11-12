FROM python:3.12.7-alpine3.20

WORKDIR /app
COPY tokens.py ./

# The database lives in the auth_tokens volume
RUN adduser -D -u 10001 tokens && mkdir /data && chown tokens /data
USER tokens

EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --retries=5 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/health || exit 1
ENTRYPOINT ["python3", "-u", "/app/tokens.py"]
