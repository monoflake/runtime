/***
 * `Upstream` and `Image` held to what they decide, the version taken past the delay, the pin read
 * from a Dockerfile, and the manifest a release carries.
 */
open Node

let day = 86_400_000.
let at = days => Date.fromString("2026-10-01T00:00:00.000Z")->Date.getTime +. days *. day
let stamp = days => Date.fromTime(at(days))->Date.toISOString

let release = (tag, days, ~prerelease=false, ~draft=false) =>
  `{"tag_name": "${tag}", "published_at": "${stamp(days)}", "prerelease": ${prerelease
      ? "true"
      : "false"}, "draft": ${draft ? "true" : "false"}}`

let releases = `[${[
    release("dev", 0., ~prerelease=true),
    release("v50.0.0", 3.),
    release("v50.0.0-rc.1", 1., ~prerelease=true),
    release("v49.0.4", 2.),
    release("v48.0.7", 2.1),
    release("v51.0.0", 4., ~draft=true),
  ]->Array.join(", ")}]`

let list = switch Upstream.github(releases) {
| Ok(list) => list
| Error(why) => JsError.throwWithMessage(why)
}

test("GitHub's releases are read without a prerelease or a draft, the v taken off", () =>
  deepEqual(list->Array.map(p => p.version), ["50.0.0", "49.0.4", "48.0.7"])
)

test("the highest release past the delay is taken, not the latest published", () => {
  // 48.0.7 is a patch to an older major, published after 49.0.4.
  deepEqual(
    Upstream.choose(list, ~delay=1440, ~now=at(3.5)),
    {take: Some("49.0.4"), held: ["50.0.0"]},
  )
  deepEqual(Upstream.choose(list, ~delay=1440, ~now=at(4.)), {take: Some("50.0.0"), held: []})
  deepEqual(
    Upstream.choose(list, ~delay=1440, ~now=at(2.)),
    {take: None, held: ["50.0.0", "49.0.4", "48.0.7"]},
  )
})

let registry = `{
  "dist-tags": {"latest": "1.20261019.1", "beta": "0.20250124.2"},
  "versions": {"0.20250124.2": {}, "1.20261018.1": {}, "1.20261019.1": {}, "1.20261021.1": {}},
  "time": {
    "created": "2026-01-01T00:00:00.000Z",
    "0.20250124.2": "${stamp(0.)}",
    "1.20261018.1": "${stamp(1.)}",
    "1.20261019.1": "${stamp(2.)}",
    "1.20261021.1": "${stamp(3.)}"
  }
}`

test(
  "npm's latest tag bounds what is taken, and a version every package holds is ready last",
  () => {
    let (latest, amd64) = switch Upstream.npm(registry) {
    | Ok(read) => read
    | Error(why) => JsError.throwWithMessage(why)
    }
    deepEqual(latest, "1.20261019.1")
    deepEqual(
      Upstream.choose(amd64, ~bound=latest, ~delay=1440, ~now=at(10.)),
      {take: Some("1.20261019.1"), held: []},
    )
    let arm64: array<Upstream.published> = [
      {version: "1.20261018.1", at: at(1.)},
      {version: "1.20261019.1", at: at(2.5)},
    ]
    let both = Upstream.everywhere([amd64, arm64])
    deepEqual(both->Array.map(p => p.version), ["1.20261018.1", "1.20261019.1"])
    deepEqual(
      Upstream.choose(both, ~bound=latest, ~delay=1440, ~now=at(3.2)),
      {take: Some("1.20261018.1"), held: ["1.20261019.1"]},
    )
    deepEqual(Upstream.npm(`{"versions": {}, "time": {}}`)->Result.isError, true)
  },
)

test("the delay is minimumReleaseAge's minutes", () => {
  deepEqual(Upstream.delay("minimumReleaseAge: 1440\n"), Ok(1440))
  deepEqual(Upstream.delay("minimumReleaseAgeExclude:\n  - x\n")->Result.isError, true)
})

let a = "a"->String.repeat(64)
let b = "b"->String.repeat(64)

let dockerfile = `ARG WASMTIME_VERSION=49.0.4
ARG WASMTIME_SHA256_AMD64=${a}
ARG WASMTIME_SHA256_ARM64="${b}"
FROM busybox AS fetch-amd64
ADD --checksum=sha256:\${WASMTIME_SHA256_AMD64} https://example.com/v\${WASMTIME_VERSION}/x86_64.tar.xz /w.tar.xz
FROM busybox AS fetch-arm64
ADD --checksum=sha256:\${WASMTIME_SHA256_ARM64} https://example.com/v\${WASMTIME_VERSION}/aarch64.tar.xz /w.tar.xz
`

test("the pin is read, its version and each architecture's hash and address", () => {
  let read = Image.read(dockerfile, ~prefix="WASMTIME")
  deepEqual(
    read,
    Ok({
      version: "49.0.4",
      fetched: dict{
        "amd64": {hash: a, address: "https://example.com/v${WASMTIME_VERSION}/x86_64.tar.xz"},
        "arm64": {hash: b, address: "https://example.com/v${WASMTIME_VERSION}/aarch64.tar.xz"},
      },
    }),
  )
  deepEqual(
    read->Result.map(pin =>
      pin.fetched
      ->Dict.getUnsafe("amd64")
      ->((f: Image.fetched) => f.address->Image.at(~prefix="WASMTIME", ~version="50.0.0"))
    ),
    Ok("https://example.com/v50.0.0/x86_64.tar.xz"),
  )
})

test("a pin with no version, a hash fetched by nothing or a hash twice is refused", () => {
  deepEqual(Image.read(dockerfile, ~prefix="WORKERD")->Result.isError, true)
  let unfetched = dockerfile->String.replace("ADD --checksum=sha256:${WASMTIME_SHA256_ARM64}", "#")
  deepEqual(Image.read(unfetched, ~prefix="WASMTIME")->Result.isError, true)
  let twice = dockerfile ++ `ARG WASMTIME_SHA256_AMD64=${b}\n`
  deepEqual(Image.read(twice, ~prefix="WASMTIME")->Result.isError, true)
})

test("an archive is named by the system before the machine, as uname -m names the machine", () => {
  deepEqual(
    Image.archive(~runtime="workerd", ~version="1.20261019.1", ~architecture="amd64"),
    "workerd-1.20261019.1-linux-x86_64.tar",
  )
  deepEqual(
    Image.archive(~runtime="wasmtime", ~version="49.0.4", ~architecture="arm64"),
    "wasmtime-49.0.4-linux-aarch64.tar",
  )
})

test("the manifest lists each archive in rdm's shape, by architecture, with the commit", () =>
  deepEqual(
    Image.manifest(
      ~runtime="workerd",
      ~version="1.20261019.1",
      ~sha="abc",
      dict{
        "arm64": {file: "workerd-1.20261019.1-linux-aarch64.tar", size: 4., sha256: b},
        "amd64": {file: "workerd-1.20261019.1-linux-x86_64.tar", size: 3., sha256: a},
      },
    )->JSON.parseOrThrow,
    JSON.parseOrThrow(
      `{"runtime": "workerd", "version": "1.20261019.1", "sha": "abc", "assets": [
        {"target": "linux-x86_64", "kind": "oci", "file": "workerd-1.20261019.1-linux-x86_64.tar", "size": 3, "sha256": "${a}"},
        {"target": "linux-aarch64", "kind": "oci", "file": "workerd-1.20261019.1-linux-aarch64.tar", "size": 4, "sha256": "${b}"}
      ]}`,
    ),
  )
)

test("a manifest built by hand names no commit", () =>
  deepEqual(
    Image.manifest(~runtime="wasmtime", ~version="49.0.4", dict{})->JSON.parseOrThrow,
    JSON.parseOrThrow(`{"runtime": "wasmtime", "version": "49.0.4", "assets": []}`),
  )
)

test("a version is tagged as itself and latest over each architecture's digest", () =>
  deepEqual(
    Image.tagged(~image="docker.io/canmi/wasmtime", ~version="49.0.4", ["sha256:aa", "sha256:bb"]),
    [
      "buildx",
      "imagetools",
      "create",
      "--tag",
      "docker.io/canmi/wasmtime:49.0.4",
      "--tag",
      "docker.io/canmi/wasmtime:latest",
      "docker.io/canmi/wasmtime@sha256:aa",
      "docker.io/canmi/wasmtime@sha256:bb",
    ],
  )
)

test("an archive pushed names its image's digest in the manifest", () =>
  deepEqual(
    Image.manifest(
      ~runtime="wasmtime",
      ~version="49.0.4",
      dict{
        "amd64": {
          file: "wasmtime-49.0.4-linux-x86_64.tar",
          size: 3.,
          sha256: a,
          digest: "sha256:aa",
        },
      },
    )->JSON.parseOrThrow,
    JSON.parseOrThrow(
      `{"runtime": "wasmtime", "version": "49.0.4", "assets": [
        {"target": "linux-x86_64", "kind": "oci", "file": "wasmtime-49.0.4-linux-x86_64.tar", "size": 3, "sha256": "${a}", "digest": "sha256:aa"}
      ]}`,
    ),
  )
)

test("a day's release is named by the UTC day, each part padded so its name sorts by date", () => {
  deepEqual(Image.day(Date.fromString("2026-09-05T23:59:00Z")->Date.getTime), "2026.09.05")
  deepEqual(Image.day(Date.fromString("2026-10-22T00:00:00Z")->Date.getTime), "2026.10.22")
  deepEqual(
    ["2026.10.22", "2026.09.05"]->Array.toSorted(String.compare),
    ["2026.09.05", "2026.10.22"],
  )
})

test("a version's line links upstream's release and the pull, and is added once", () => {
  let line = Image.line(
    ~runtime="workerd",
    ~version="1.20261021.1",
    ~upstream="cloudflare/workerd",
    ~image="canmi/workerd",
  )
  deepEqual(
    line,
    "- [workerd 1.20261021.1](https://github.com/cloudflare/workerd/releases/tag/v1.20261021.1) → [`docker pull canmi/workerd:1.20261021.1`](https://hub.docker.com/r/canmi/workerd/tags?name=1.20261021.1)",
  )
  let other = "- [wasmtime 50.0.0](x) → [`docker pull canmi/wasmtime:50.0.0`](y)"
  deepEqual(Image.appended("", line), line)
  deepEqual(Image.appended(other, line), `${other}\n${line}`)
  deepEqual(Image.appended(`${other}\n${line}\n`, line), `${other}\n${line}`)
})

test("a version is released once a published release holds its manifest", () => {
  let releases =
    JSON.parseOrThrow(`[
    {"tag_name": "2026.10.22", "draft": true, "assets": [{"name": "wasmtime-50.0.0.json"}]},
    {"tag_name": "2026.10.21", "draft": false, "assets": [
      {"name": "workerd-1.20261021.1-linux-x86_64.tar"}, {"name": "workerd-1.20261021.1.json"}
    ]},
    {"tag_name": "2026.10.20", "draft": false, "assets": [{"name": "workerd-1.20261020.1-linux-x86_64.tar"}]}
  ]`)
    ->JSON.Decode.array
    ->Option.getOr([])
  deepEqual(Image.released(releases, ~runtime="workerd", ~version="1.20261021.1"), true)
  deepEqual(Image.released(releases, ~runtime="wasmtime", ~version="50.0.0"), false)
  deepEqual(Image.released(releases, ~runtime="workerd", ~version="1.20261020.1"), false)
  deepEqual(Image.entry(~runtime="workerd", ~version="1.20261021.1"), "workerd-1.20261021.1.json")
})
