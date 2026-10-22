/*** `Dockerfiles` held to the runtime's pin it writes and the newest version it reads. */
open Node

let old = "sha256:" ++ String.repeat("1", 64)
let other = "sha256:" ++ String.repeat("3", 64)

let dockerfile = `ARG WASMTIME_VERSION=49.0.4
ARG WASMTIME_SHA256_AMD64=aaa
ARG WASMTIME_SHA256_ARM64=bbb

FROM --platform=$BUILDPLATFORM busybox:1.37.0-glibc@${old} AS fetch-amd64
ARG WASMTIME_VERSION
FROM --platform=$BUILDPLATFORM busybox:1.37.0-glibc@${old} AS fetch-arm64
FROM fetch-\${TARGETARCH} AS fetch
FROM gcr.io/distroless/cc-debian13:nonroot@${other}
ARG WASMTIME_VERSION`

test(
  "a runtime's version and each architecture's hash are set by their ARGs, the rest kept",
  () => {
    let moved = Dockerfiles.repinned(
      dockerfile,
      ~prefix="WASMTIME",
      ~version="50.0.0",
      dict{"amd64": "ccc", "arm64": "ddd"},
    )
    deepEqual(
      moved->String.split("\n")->Array.slice(~start=0, ~end=3),
      [
        "ARG WASMTIME_VERSION=50.0.0",
        "ARG WASMTIME_SHA256_AMD64=ccc",
        "ARG WASMTIME_SHA256_ARM64=ddd",
      ],
    )
    deepEqual(moved->String.split("\n")->Array.get(5), Some("ARG WASMTIME_VERSION"))
  },
)

test("the newest version a release holds is read from its archives' names", () => {
  let names = [
    "workerd-1.20261021.1-linux-x86_64.tar",
    "workerd-1.20261022.1-linux-aarch64.tar",
    "workerd-1.20261020.1-linux-x86_64.tar",
    "wasmtime-50.0.0-linux-x86_64.tar",
    "manifest.json",
  ]
  deepEqual(Dockerfiles.newest(names, ~runtime="workerd"), Some("1.20261022.1"))
  deepEqual(Dockerfiles.newest(names, ~runtime="wasmtime"), Some("50.0.0"))
  deepEqual(Dockerfiles.newest(names, ~runtime="other"), None)
})
