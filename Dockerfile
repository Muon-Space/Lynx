# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian instead of
# Alpine to avoid DNS resolution issues in production.
#
# https://hub.docker.com/r/hexpm/elixir/tags?page=1&name=ubuntu
# https://hub.docker.com/_/ubuntu?tab=tags
#
#
# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the build image
#   - https://hub.docker.com/_/debian?tab=tags&page=1&name=bullseye-20240130-slim - for the release image
#   - https://pkgs.org/ - resource for finding needed packages
#   - Ex: hexpm/elixir:1.16.1-erlang-26.2.1-debian-bullseye-20240130-slim
#
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.4.2
ARG UBUNTU_VERSION=noble-20260410

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-ubuntu-${UBUNTU_VERSION}"
ARG RUNNER_IMAGE="ubuntu:resolute"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update --allow-releaseinfo-change -y && \
    apt-get install -y build-essential git npm && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile --quiet

COPY priv priv

COPY lib lib

COPY assets assets
RUN cd assets && npm install

# Compile Elixir code first so the LiveView mix compiler writes the
# `_build/$MIX_ENV/phoenix-colocated/lynx/` manifest. esbuild needs that
# directory to resolve `import {hooks} from "phoenix-colocated/lynx"`.
RUN mix compile

# Bundle assets (consumes the colocated hooks manifest emitted above).
RUN mix esbuild lynx --minify
RUN mix tailwind lynx --minify

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

RUN rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update --allow-releaseinfo-change -y && \
    apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/lynx ./

USER nobody

CMD ["/app/bin/server"]
