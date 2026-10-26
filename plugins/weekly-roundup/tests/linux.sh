#!/bin/bash
# Run every test in a Debian container (needs docker). Runs as a normal user: root ignores
# file permissions, so the guard's unwritable-record tests would wrongly fail.
cd "$(dirname "$0")/.." || exit 1
docker run --rm -v "$PWD":/src:ro debian:stable-slim bash -c '
  apt-get update -qq >/dev/null && apt-get install -y -qq jq git >/dev/null 2>&1 || exit 1
  useradd -m -s /bin/bash u && cp -r /src /w && chown -R u /w
  su u -c "cd /w && git config --global user.email t@t && fail=0
    for t in tests/*-test.sh; do echo \"== \$t\"; bash \$t || fail=1; done; exit \$fail"'
