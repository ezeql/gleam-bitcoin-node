FROM ghcr.io/gleam-lang/gleam:nightly-erlang

USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl tar \
  && arch="$(uname -m)" \
  && case "$arch" in \
       aarch64|arm64) platform=aarch64-linux-gnu ;; \
       x86_64) platform=x86_64-linux-gnu ;; \
       *) echo "unsupported arch $arch" >&2; exit 1 ;; \
     esac \
  && curl -fsSL -o /tmp/bitcoin.tar.gz \
       "https://bitcoincore.org/bin/bitcoin-core-32.1/bitcoin-32.1-${platform}.tar.gz" \
  && tar -C /usr/local --strip-components=1 -xzf /tmp/bitcoin.tar.gz \
  && rm /tmp/bitcoin.tar.gz \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY gleam.toml ./
COPY src src
COPY test test
RUN gleam deps download && gleam build

COPY docker/e2e.sh /e2e.sh
RUN chmod +x /e2e.sh
CMD ["/e2e.sh"]
