# wasmtime, the WebAssembly component runtime the machine driver runs in a container, RFC vr5lw.
ARG WASMTIME_VERSION=50.0.0
ARG WASMTIME_SHA256_AMD64=77c19ee0437991f9ac7837b9c269d9c7076744f85dad263fea5214cc2723c7ff
ARG WASMTIME_SHA256_ARM64=10f9ad1f8539d2e04e041cc622de6a270109ab1e43a6be1f69843c2082166832

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

FROM gcr.io/distroless/cc-debian13:nonroot@sha256:83b9b50586253821cf63ffcec87d3d94265a093ad30da232039af962dd8f4edf
ARG WASMTIME_VERSION
LABEL org.opencontainers.image.version=${WASMTIME_VERSION}
COPY --from=fetch --chmod=0755 /wasmtime /usr/local/bin/wasmtime
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/wasmtime"]
