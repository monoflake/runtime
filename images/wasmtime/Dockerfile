# wasmtime, the WebAssembly component runtime the machine driver runs in a container, RFC vr5lw.
ARG WASMTIME_VERSION=50.0.1
ARG WASMTIME_SHA256_AMD64=685466455dd42a14774a86c36c8f2e45cbb9bd6d92a850139315df60a75498a5
ARG WASMTIME_SHA256_ARM64=d737e077416d78fbfb0a008229ec27d6a0fd5a4924874b8c38b293c850cf4094

FROM --platform=$BUILDPLATFORM busybox:1.37.0-glibc@sha256:42a9ff19af33811ee466b24c66384461d37c32dcc28d1d27d49b8aca816bd5ee AS fetch-amd64
ARG WASMTIME_VERSION
ARG WASMTIME_SHA256_AMD64
ADD --checksum=sha256:${WASMTIME_SHA256_AMD64} https://github.com/bytecodealliance/wasmtime/releases/download/v${WASMTIME_VERSION}/wasmtime-v${WASMTIME_VERSION}-x86_64-linux.tar.xz /wasmtime.tar.xz

FROM --platform=$BUILDPLATFORM busybox:1.37.0-glibc@sha256:42a9ff19af33811ee466b24c66384461d37c32dcc28d1d27d49b8aca816bd5ee AS fetch-arm64
ARG WASMTIME_VERSION
ARG WASMTIME_SHA256_ARM64
ADD --checksum=sha256:${WASMTIME_SHA256_ARM64} https://github.com/bytecodealliance/wasmtime/releases/download/v${WASMTIME_VERSION}/wasmtime-v${WASMTIME_VERSION}-aarch64-linux.tar.xz /wasmtime.tar.xz

FROM fetch-${TARGETARCH} AS fetch
RUN mkdir /out && tar -xJf /wasmtime.tar.xz -C /out && mv /out/*/wasmtime /wasmtime

FROM gcr.io/distroless/cc-debian13:nonroot@sha256:3ee00291cf386ec52a552e6a858d555debd74776eb4bfa53fa3df2cd6677515e
ARG WASMTIME_VERSION
LABEL org.opencontainers.image.version=${WASMTIME_VERSION}
COPY --from=fetch --chmod=0755 /wasmtime /usr/local/bin/wasmtime
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/wasmtime"]
