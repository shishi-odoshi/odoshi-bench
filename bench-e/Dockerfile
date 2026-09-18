# Track E image: the SUPERVISOR under test, nothing else.
#
# Track E measures odoshi's own boot/drain scheduling, so the subject is the
# gem — not the Rails app. A slim image with only the published gem keeps the
# 0.3.1-vs-0.4.0 A/B honest (the only difference between the two images is the
# gem version) and cheap enough for CI. Children are plain fixture commands
# with a deliberately slow readiness, so the measurement is scheduling, not
# Rails boot.
#
#   docker build --build-arg ODOSHI_VERSION=0.3.1 -t odoshi-bench-e:0.3.1 bench-e
#   docker build --build-arg ODOSHI_VERSION=0.4.0 -t odoshi-bench-e:0.4.0 bench-e
FROM ruby:3.4

RUN apt-get update && \
    apt-get install -y --no-install-recommends procps && \
    rm -rf /var/lib/apt/lists/*

# The gem under test, pinned. Registry flakes are retried, not fatal.
ARG ODOSHI_VERSION=0.4.0
RUN set -eux; \
    for i in 1 2 3 4 5; do \
      gem install odoshi --version "$ODOSHI_VERSION" --no-document && break; \
      [ "$i" = 5 ] && exit 1; \
      echo "gem install odoshi $ODOSHI_VERSION failed (attempt $i) — retrying in 10s"; sleep 10; \
    done; \
    odoshi version

# Recorded so every Track E row can state the version it actually measured
# (the gha-cache lesson: never trust the tag, record the artifact).
ENV ODOSHI_VERSION=${ODOSHI_VERSION}

WORKDIR /bench
CMD ["odoshi", "version"]
