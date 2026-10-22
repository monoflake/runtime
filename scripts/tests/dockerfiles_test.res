/*** `Dockerfiles` held to what it reads from a Dockerfile and writes into it again. */
open Node

let old = "sha256:" ++ String.repeat("1", 64)
let now = "sha256:" ++ String.repeat("2", 64)
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
  "each base pinned by digest is read by its line, a stage named after another passed over",
  () =>
    deepEqual(
      Dockerfiles.bases(dockerfile)->Array.map(({index, image, tag, digest}) => (
        index,
        image,
        tag,
        digest,
      )),
      [
        (4, "busybox", "1.37.0-glibc", old),
        (6, "busybox", "1.37.0-glibc", old),
        (8, "gcr.io/distroless/cc-debian13", "nonroot", other),
      ],
    ),
)

test("a base moves to its tag's digest, its platform, stage name and tag kept", () => {
  let moved = Dockerfiles.rebased(dockerfile, dict{"busybox:1.37.0-glibc": now})
  deepEqual(
    moved->String.split("\n")->Array.get(4),
    Some(`FROM --platform=$BUILDPLATFORM busybox:1.37.0-glibc@${now} AS fetch-amd64`),
  )
  deepEqual(moved->String.split("\n")->Array.get(8), dockerfile->String.split("\n")->Array.get(8))
  deepEqual(Dockerfiles.rebased(dockerfile, dict{}), dockerfile)
})

test("an image is found on Docker Hub unless its first part names a host", () => {
  deepEqual(Dockerfiles.located("busybox"), ("registry-1.docker.io", "library/busybox"))
  deepEqual(Dockerfiles.located("canmi/workerd"), ("registry-1.docker.io", "canmi/workerd"))
  deepEqual(
    Dockerfiles.located("docker.io/canmi/workerd"),
    ("registry-1.docker.io", "canmi/workerd"),
  )
  deepEqual(
    Dockerfiles.located("gcr.io/distroless/cc-debian13"),
    ("gcr.io", "distroless/cc-debian13"),
  )
  deepEqual(Dockerfiles.located("localhost:5055/canmi/x"), ("localhost:5055", "canmi/x"))
})

test("a registry's challenge names the token's address, its service and scope asked", () => {
  deepEqual(
    Dockerfiles.challenged(`Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:library/busybox:pull"`),
    Some(
      "https://auth.docker.io/token?service=registry.docker.io&scope=repository%3Alibrary%2Fbusybox%3Apull",
    ),
  )
  deepEqual(
    Dockerfiles.challenged(`Bearer realm="https://gcr.io/v2/token"`),
    Some("https://gcr.io/v2/token"),
  )
  deepEqual(Dockerfiles.challenged(`Basic realm="x"`), None)
})

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
