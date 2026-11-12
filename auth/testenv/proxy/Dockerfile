FROM python:3.12.7-alpine3.20
# openssl: signs the test assertions
RUN apk add --no-cache openssl
COPY proxy.py /proxy.py
ENTRYPOINT ["python3", "-u", "/proxy.py"]
