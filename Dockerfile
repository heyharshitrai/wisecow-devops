# syntax=docker/dockerfile:1
#
# The application itself is untouched. app/wisecow.sh is byte-identical to
# upstream (sha256 7531eee4983f90db84fcdb3cba0258b8f4f72adf387a664d6cea0c06e4760ac9).
# Everything in this file is packaging.
FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      cowsay \
      fortune-mod \
      fortunes-min \
      netcat-openbsd \
      tini \
 && rm -rf /var/lib/apt/lists/*

# /usr/games is missing from PATH in a non-login shell. Leave it out and the
# script's own prerequisite check fails with "Install prerequisites." and exits 1.
ENV PATH="/usr/games:${PATH}"

# The script runs `mkfifo response` in its working directory, so that directory
# has to stay writable even when the root filesystem is mounted read-only.
# Keeping it away from the script itself means a read-only mount cannot shadow
# the binary.
RUN groupadd --gid 10001 wisecow \
 && useradd --uid 10001 --gid 10001 --no-create-home \
      --shell /usr/sbin/nologin wisecow \
 && mkdir -p /var/lib/wisecow \
 && chown 10001:10001 /var/lib/wisecow

WORKDIR /var/lib/wisecow

# 0555, owned by root: the process never needs to modify its own script.
COPY --chown=0:0 --chmod=0555 app/wisecow.sh /usr/local/bin/wisecow.sh

USER 10001:10001
EXPOSE 4499

# The server answers `HTTP/1.1 200` and then closes the socket. So the only
# thing worth asserting is the status line.
HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=3 \
  CMD printf 'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' \
      | nc -w 3 127.0.0.1 4499 | head -n 1 | grep -q '200'

# bash does not forward SIGTERM. Without an init, every rollout sits in
# Terminating for the full grace period.
#
# -g   send the signal to the process group, so `nc` and `cat` get it too
# -e   remap bash's 143 (128+SIGTERM) to 0. Otherwise every scale-down leaves the
#      pod showing Error in `kubectl get pods` for a few seconds, which is
#      technically accurate and completely misleading.
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "-g", "-e", "143", "--"]
CMD ["/usr/local/bin/wisecow.sh"]
