# odoshi-bench app image: ONE Rails app, generated at image build from
# odoshi-template's template.rb (published main), patched with the benchmark
# surface (marker jobs, wedge middleware, Procfile, per-track supervisor
# configs), plus every contender's tooling: odoshi (via the app bundle,
# published gem), foreman (gem), overmind (release binary + tmux), and wrk
# for the latency track. All contenders run THIS image against THIS app —
# same code, same gems, same base image.
FROM ruby:3.4

# wrk: Track B latency load tool. tmux: overmind's backend. procps: pgrep/ps.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libpq-dev postgresql-client procps curl git tmux wrk && \
    rm -rf /var/lib/apt/lists/*

ENV BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3 \
    LANG=C.UTF-8

# Contender: foreman (published gem, no pins — its docs recommend nothing else).
RUN gem install rails foreman --no-document && \
    gem install pg puma bootsnap propshaft importmap-rails turbo-rails \
                stimulus-rails jbuilder solid_queue solid_cable solid_cache \
                thruster odoshi --no-document && \
    gem install json --version "< 3.0" --no-document

# Contender: overmind (pinned release binary — its documented install path).
# Release downloads are retried: registry/CDN flakes are an observed CI
# failure mode (odoshi-integration lesson), not a reason to fail a build.
ARG TARGETARCH
ARG OVERMIND_VERSION=v2.5.1
RUN set -eux; \
    url="https://github.com/DarthSim/overmind/releases/download/${OVERMIND_VERSION}/overmind-${OVERMIND_VERSION}-linux-${TARGETARCH}.gz"; \
    for i in 1 2 3 4 5; do \
      curl -fsSL --retry 3 "$url" -o /tmp/overmind.gz && break; \
      [ "$i" = 5 ] && exit 1; \
      echo "overmind download failed (attempt $i) — retrying in 10s"; sleep 10; \
    done; \
    gunzip /tmp/overmind.gz && \
    install -m 0755 /tmp/overmind /usr/local/bin/overmind && \
    overmind --version

# Generate the ONE app under test from the published template (same artifact
# `rails new -m <raw url>` users get). TEMPLATE_URL overridable for hermetic
# rebuilds; retried for the same registry-flake reason as above.
ARG TEMPLATE_URL=https://raw.githubusercontent.com/shishi-odoshi/odoshi-template/main/template.rb
RUN set -eux; \
    for i in 1 2 3 4 5; do \
      curl -fsSL --retry 3 "$TEMPLATE_URL" -o /tmp/template.rb && break; \
      [ "$i" = 5 ] && exit 1; \
      echo "template fetch failed (attempt $i) — retrying in 10s"; sleep 10; \
    done; \
    rails new /app \
      --database=postgresql \
      --skip-git --skip-docker --skip-kamal --skip-ci \
      -m /tmp/template.rb

WORKDIR /app

# Benchmark surface (documented deltas only — see app/patches/apply.sh).
COPY patches /patches
RUN /patches/apply.sh /app

# Propshaft precompile so production boot never surprises us mid-benchmark.
RUN SECRET_KEY_BASE=build-only RAILS_ENV=production DB_HOST=none bin/rails assets:precompile

CMD ["sleep", "infinity"]
