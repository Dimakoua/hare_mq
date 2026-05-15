# [Choice] Elixir version: 1.15, 1.14, 1.13
FROM elixir:1.15-alpine

# Install any extra OS packages needed for the project
RUN apk add --no-cache \
     git \
     xdg-utils \
     curl \
     gnupg \
     ca-certificates \
     wget \
     bash

# Create vscode user for development
RUN addgroup -S vscode && adduser -S vscode -G vscode -s /bin/bash

# Note: RabbitMQ server is not included in Alpine container
# For local development, use Docker Compose or run RabbitMQ separately
# For testing, rabbit_mq dependency in mix.exs will provide the necessary Erlang client

# Ensure build tools are available
RUN mix local.hex --force \
  && mix local.rebar --force

# Optional: verify dependency toolchain
RUN mix hex.info || true

# Set workdir
WORKDIR /workspace

# Ensure vscode user has appropriate permissions
RUN chown -R vscode:vscode /workspace
