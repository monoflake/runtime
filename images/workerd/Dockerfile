# workerd, the V8 isolate runtime the machine driver runs in a container, RFC vr5lw.
ARG WORKERD_VERSION=1.20261031.1
ARG WORKERD_SHA256_AMD64=30a5dc38f261a15fffda8c769a2f39b684b1aefe9e293404cbb9707cbfdba1e9
ARG WORKERD_SHA256_ARM64=222ac68963966f35c8f28e59250d870d7dc73aa60a1ae6718340c3b391604301

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
