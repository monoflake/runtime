# workerd, the V8 isolate runtime the machine driver runs in a container, RFC vr5lw.
ARG WORKERD_VERSION=1.20261108.1
ARG WORKERD_SHA256_AMD64=8d5cae5c3fd2c07b38238219bf92688c1e5b75880a6d17e18da6879ac7000ddb
ARG WORKERD_SHA256_ARM64=ee0cb1a59ce628c68bfc2f9c2f1bd638ac11e1a11d226b6bc15147fbbebafa9b

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
