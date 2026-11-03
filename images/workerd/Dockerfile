# workerd, the V8 isolate runtime the machine driver runs in a container, RFC vr5lw.
ARG WORKERD_VERSION=1.20261101.1
ARG WORKERD_SHA256_AMD64=41899412384b33e08cfe38b9bd889dd006cfb519a44f29b496d855370c0b387b
ARG WORKERD_SHA256_ARM64=609d84b29c20cfd976d84d210825af867375bf2d06b7c10e1554175c597af795

FROM --platform=$BUILDPLATFORM busybox:1.37.0-glibc@sha256:42a9ff19af33811ee466b24c66384461d37c32dcc28d1d27d49b8aca816bd5ee AS fetch-amd64
ARG WORKERD_VERSION
ARG WORKERD_SHA256_AMD64
ADD --checksum=sha256:${WORKERD_SHA256_AMD64} https://registry.npmjs.org/@cloudflare/workerd-linux-64/-/workerd-linux-64-${WORKERD_VERSION}.tgz /workerd.tgz

FROM --platform=$BUILDPLATFORM busybox:1.37.0-glibc@sha256:42a9ff19af33811ee466b24c66384461d37c32dcc28d1d27d49b8aca816bd5ee AS fetch-arm64
ARG WORKERD_VERSION
ARG WORKERD_SHA256_ARM64
ADD --checksum=sha256:${WORKERD_SHA256_ARM64} https://registry.npmjs.org/@cloudflare/workerd-linux-arm64/-/workerd-linux-arm64-${WORKERD_VERSION}.tgz /workerd.tgz

FROM fetch-${TARGETARCH} AS fetch
RUN tar -xzf /workerd.tgz -C / package/bin/workerd

FROM gcr.io/distroless/base-nossl-debian13:nonroot@sha256:e6b0f82595aa1edde72c8054de7a9dca30f0f8f54820c37a167c0ddfc21c5c67
ARG WORKERD_VERSION
LABEL org.opencontainers.image.version=${WORKERD_VERSION}
COPY --from=fetch --chmod=0755 /package/bin/workerd /usr/local/bin/workerd
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/workerd"]
