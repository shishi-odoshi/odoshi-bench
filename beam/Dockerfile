# Track D sidecar: the beam (Elixir) Solid Queue worker consuming the same
# Postgres schema as bin/jobs, from its published main branch — mirroring
# odoshi-integration's runner. Network bootstrap steps are retried: hex.pm
# timeouts are an observed transient failure mode, not a build verdict.
FROM elixir:1.18

RUN apt-get update && \
    apt-get install -y --no-install-recommends git procps && \
    rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod

WORKDIR /runner
RUN for i in 1 2 3 4 5; do \
      mix local.hex --force && mix local.rebar --force && break; \
      [ "$i" = 5 ] && exit 1; \
      echo "hex/rebar bootstrap failed (attempt $i) — retrying in 15s"; sleep 15; \
    done

COPY runner/mix.exs ./
RUN for i in 1 2 3 4 5; do \
      mix deps.get && break; \
      [ "$i" = 5 ] && exit 1; \
      echo "mix deps.get failed (attempt $i) — retrying in 15s"; sleep 15; \
    done && \
    mix deps.compile

COPY runner/lib lib
RUN mix compile

CMD ["mix", "run", "--no-halt"]
