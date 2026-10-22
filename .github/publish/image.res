/***
 * What an image is built from, as its Dockerfile pins it, and what a release of it holds, an OCI
 * archive per architecture and what `built.json` names of each, platform's RFC ge55b.
 */

/** One architecture's download, its SHA-256 and its address with the version left to fill. */
type fetched = {hash: string, address: string}

/** The Dockerfile's pin, its version `ARG` and each architecture's download, by Docker's name. */
type pin = {version: string, fetched: dict<fetched>}

/** Every match of `pattern` in `text`, in order. */
let all = (pattern, text) => {
  let global = RegExp.fromString(pattern, ~flags="gm")
  let found = []
  let rec next = () =>
    switch global->RegExp.exec(text) {
    | Some(m) =>
      found->Array.push(m->RegExp.Result.matches)
      next()
    | None => ()
    }
  next()
  found
}

/** An `ARG` named `name` with a default, the default its one group. */
let arg = name => `^[ \\t]*ARG[ \\t]+${name}="?([^"\\s]+)"?[ \\t]*$`

/** The pin under `prefix`, `WORKERD` for `WORKERD_VERSION` and `WORKERD_SHA256_AMD64`. */
let read = (text, ~prefix) => {
  let hashes = all(
    `^[ \\t]*ARG[ \\t]+${prefix}_SHA256_([A-Z0-9]+)="?([0-9a-f]{64})"?[ \\t]*$`,
    text,
  )
  let adds = all(
    `^[ \\t]*ADD[ \\t]+--checksum=sha256:\\$\\{${prefix}_SHA256_([A-Z0-9]+)\\}[ \\t]+(\\S+)`,
    text,
  )
  switch all(arg(`${prefix}_VERSION`), text) {
  | [[Some(version)]] =>
    let fetched = Dict.make()
    let refused = hashes->Array.reduce(None, (refused, groups) =>
      switch (refused, groups) {
      | (Some(_), _) => refused
      | (None, [Some(architecture), Some(hash)]) =>
        let name = architecture->String.toLowerCase
        switch adds->Array.filter(add => add[0] == Some(Some(architecture))) {
        | _ if fetched->Dict.get(name) != None => Some(`${prefix}_SHA256_${architecture} twice`)
        | [[_, Some(address)]] =>
          fetched->Dict.set(name, {hash, address})
          None
        | [] => Some(`no ADD fetches with ${prefix}_SHA256_${architecture}`)
        | _ => Some(`more than one ADD fetches with ${prefix}_SHA256_${architecture}`)
        }
      | _ => Some(`a ${prefix}_SHA256_ ARG not read`)
      }
    )
    switch (refused, fetched->Dict.keysToArray) {
    | (Some(why), _) => Error(why)
    | (None, []) => Error(`no ${prefix}_SHA256_ ARG with a default`)
    | (None, _) => Ok({version, fetched})
    }
  | [] => Error(`no ${prefix}_VERSION ARG with a default`)
  | _ => Error(`more than one ${prefix}_VERSION ARG`)
  }
}

/** An address the Dockerfile writes with `${PREFIX_VERSION}`, at `version`. */
let at = (address, ~prefix, ~version) =>
  address->String.replaceAll(`\${${prefix}_VERSION}`, version)

/** The machine an architecture is filed under, as `uname -m` prints it, by Docker's name. */
let machine = architecture =>
  switch architecture {
  | "amd64" => "x86_64"
  | "arm64" => "aarch64"
  | other => other
  }

/** What an archive is built for, the system before the machine, as rdm names its own. */
let target = architecture => `linux-${machine(architecture)}`

/** An architecture's archive, as the release names the asset. */
let archive = (~runtime, ~version, ~architecture) =>
  `${runtime}-${version}-${target(architecture)}.tar`

/** The tags a version is published under, its own and `latest`, over each architecture's digest. */
let tagged = (~image, ~version, digests) =>
  [
    "buildx",
    "imagetools",
    "create",
    "--tag",
    `${image}:${version}`,
    "--tag",
    `${image}:latest`,
    ...digests->Array.map(digest => `${image}@${digest}`),
  ]

let field = (json, key) => json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(key))
let text = (json, key) => json->field(key)->Option.flatMap(JSON.Decode.string)
let list = (json, key) => json->field(key)->Option.flatMap(JSON.Decode.array)->Option.getOr([])

/** Where upstream released a version, its repository, its tag and the commit the tag names. */
type upstream = {repository: string, tag: string, commit: string}

/** One architecture's archive as `built.json` names it, its path and its image's digest. */
type archived = {architecture: string, path: string, digest: string}

/** A version as `built.json` names it for the workspace's scripts/release, the commit here that
 * built it, upstream's release of it, each archive by its target, and its row in the notes. */
let built = (~runtime, ~version, ~commit, ~upstream: upstream, ~row, archives: array<archived>) =>
  JSON.Encode.object(
    dict{
      "name": JSON.Encode.string(runtime),
      "version": JSON.Encode.string(version),
      "commit": JSON.Encode.string(commit),
      "upstream": JSON.Encode.object(
        dict{
          "repository": JSON.Encode.string(upstream.repository),
          "tag": JSON.Encode.string(upstream.tag),
          "commit": JSON.Encode.string(upstream.commit),
        },
      ),
      "assets": archives
      ->Array.toSorted((a, b) => String.compare(a.architecture, b.architecture))
      ->Array.map(({architecture, path, digest}) =>
        JSON.Encode.object(
          dict{
            "target": JSON.Encode.string(target(architecture)),
            "kind": JSON.Encode.string("oci"),
            "path": JSON.Encode.string(path),
            "digest": JSON.Encode.string(digest),
          },
        )
      )
      ->JSON.Encode.array,
      "row": row->Array.map(JSON.Encode.string)->JSON.Encode.array,
    },
  )

/** Whether what the published releases list, as the workspace's `release listed` prints it, holds
 * the version. */
let listed = (entries: array<JSON.t>, ~runtime, ~version) =>
  entries->Array.some(entry =>
    entry->text("name") == Some(runtime) && entry->text("version") == Some(version)
  )

/** A version's row, upstream's release of it linked, upstream's commit short and linked, then the
 * image linked to its tag on Docker Hub, under workspace.toml's `[release]` columns. */
let row = (~runtime, ~version, ~upstream: upstream, ~image) => [
  runtime,
  `[${version}](https://github.com/${upstream.repository}/releases/tag/${upstream.tag})`,
  `[\`${upstream.commit->String.slice(
      ~start=0,
      ~end=7,
    )}\`](https://github.com/${upstream.repository}/commit/${upstream.commit})`,
  `[\`${image}:${version}\`](https://hub.docker.com/r/${image}/tags?name=${version})`,
]
