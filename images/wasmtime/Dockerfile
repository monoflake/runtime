# wasmtime, the WebAssembly component runtime the machine driver runs in a container, RFC vr5lw.
ARG WASMTIME_VERSION=51.0.0
ARG WASMTIME_SHA256_AMD64=a18020674fac4107f329bc9ed720ea9c88e4b30a61e8a527787bcce051123d32
ARG WASMTIME_SHA256_ARM64=a263f34aefad1b24ba4d9ca635ddfea415f4acfe3f3f1bb6d4525c34fc6a7397

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

FROM gcr.io/distroless/cc-debian13:nonroot@sha256:29ee70762214fe8190cea04ef1c0a84a8365879e047ce8f911ae5a5ab2355fa2
ARG WASMTIME_VERSION
LABEL org.opencontainers.image.version=${WASMTIME_VERSION}
COPY --from=fetch --chmod=0755 /wasmtime /usr/local/bin/wasmtime
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/wasmtime"]
