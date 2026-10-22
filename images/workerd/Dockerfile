# workerd, the V8 isolate runtime the machine driver runs in a container, RFC vr5lw.
ARG WORKERD_VERSION=1.20261021.1
ARG WORKERD_SHA256_AMD64=3b8b7d9bf4e25f8c8f4f47875f2b7c68367f2b254fb31235c90fe614e6ca4aa0
ARG WORKERD_SHA256_ARM64=30defa7810a78ca486aaee93d69fb6627bc420c3318777c982dc8af187e598c0

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

FROM gcr.io/distroless/base-nossl-debian13:nonroot@sha256:6d92083da644c5fceb58fb1dc50e88b3c1aa0d8b6099678223fbb801bd72962b
ARG WORKERD_VERSION
LABEL org.opencontainers.image.version=${WORKERD_VERSION}
COPY --from=fetch --chmod=0755 /package/bin/workerd /usr/local/bin/workerd
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/workerd"]
