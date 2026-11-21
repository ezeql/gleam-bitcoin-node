FROM ghcr.io/gleam-lang/gleam:nightly-erlang

USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates curl tar git build-essential cmake pkg-config python3 \
       libboost-dev \
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

# libbitcoinkernel is not in the Core release tarball. Build only that library.
RUN git clone --depth 1 --branch v32.1 https://github.com/bitcoin/bitcoin /tmp/bitcoin \
  && cmake -S /tmp/bitcoin -B /tmp/bitcoin/build-kernel \
       -DBUILD_KERNEL_LIB=ON -DBUILD_SHARED_LIBS=ON \
       -DBUILD_DAEMON=OFF -DBUILD_CLI=OFF -DBUILD_TESTS=OFF \
       -DENABLE_WALLET=OFF -DENABLE_IPC=OFF \
  && cmake --build /tmp/bitcoin/build-kernel -j"$(nproc)" \
  && lib="$(find /tmp/bitcoin/build-kernel -name 'libbitcoinkernel.so' -print -quit)" \
  && cp -L "$lib" /usr/local/lib/libbitcoinkernel.so \
  && find "$(dirname "$lib")" -name 'libsecp256k1.so*' -exec cp -L {} /usr/local/lib/ \; \
  && cp /tmp/bitcoin/src/kernel/bitcoinkernel.h /usr/local/include/bitcoinkernel.h \
  && ldconfig \
  && rm -rf /tmp/bitcoin

ENV LD_LIBRARY_PATH=/usr/local/lib

WORKDIR /src
COPY gleam.toml ./
COPY src src
COPY native native
COPY test test
RUN gleam deps download && gleam build \
  && erl -noshell -eval 'io:format("~ts/erts-~ts/include", [code:root_dir(), erlang:system_info(version)]), halt().' > /tmp/erts_inc \
  && gcc -fPIC -shared -O2 -std=c11 -I"$(cat /tmp/erts_inc)" -I/usr/local/include \
       native/kernel_nif.c -o /usr/local/lib/gleam_kernel_nif.so \
       -L/usr/local/lib -lbitcoinkernel -Wl,-rpath,/usr/local/lib

COPY docker/e2e.sh /e2e.sh
RUN chmod +x /e2e.sh
CMD ["/e2e.sh"]
