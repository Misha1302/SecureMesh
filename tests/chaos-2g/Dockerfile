FROM python:3.13-alpine@sha256:420cd0bf0f3998275875e02ecd5808168cf0843cbb4d3c536432f729247b2acc
RUN apk add --no-cache iproute2 iproute2-tc
COPY proxy.py configure.sh /netem/
ENTRYPOINT ["python3", "/netem/proxy.py"]
