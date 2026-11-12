FROM python:3.12.7-alpine3.20

RUN pip install --no-cache-dir pyyaml==6.0.2

WORKDIR /app
COPY presets.py configurator.py ./

ENTRYPOINT ["python3", "-u", "/app/configurator.py"]
CMD ["apply"]
