/***
 * What an image is built from, as its Dockerfile pins it, and what a release of it holds, an OCI
 * archive per architecture and the manifest naming each, platform's RFC ge55b.
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

/** The release a day's builds go into, named by the UTC day with each part padded, so the names
 * sort by their text as they do by date. */
let day = now => {
  let date = Date.fromTime(now)
  let pad = n => n->Int.toString->String.padStart(2, "0")
  `${date->Date.getUTCFullYear->Int.toString}.${pad(date->Date.getUTCMonth + 1)}.${pad(
      date->Date.getUTCDate,
    )}`
}

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

/** One archive as the manifest lists it, with its image's digest where it was pushed. */
type asset = {file: string, size: float, sha256: string, digest?: string}

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

/** The one manifest a release carries, every version it holds listed in it, written last. */
let manifestFile = "manifest.json"

/** Where upstream released a version, its repository, its tag and the commit the tag names. */
type upstream = {repository: string, tag: string, commit: string}

/** A version as the manifest lists it, upstream's release of it, the commit here that built it
 * where one is known, and each archive with its target, size, SHA-256 and image digest. */
let entry = (~runtime, ~version, ~commit=?, ~upstream: upstream, assets: dict<asset>) => {
  let fields = dict{
    "runtime": JSON.Encode.string(runtime),
    "version": JSON.Encode.string(version),
  }
  commit->Option.forEach(commit => fields->Dict.set("commit", JSON.Encode.string(commit)))
  fields->Dict.set(
    "upstream",
    JSON.Encode.object(
      dict{
        "repository": JSON.Encode.string(upstream.repository),
        "tag": JSON.Encode.string(upstream.tag),
        "commit": JSON.Encode.string(upstream.commit),
      },
    ),
  )
  fields->Dict.set(
    "assets",
    assets
    ->Dict.toArray
    ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
    ->Array.map(((architecture, {file, size, sha256, ?digest})) => {
      let asset = dict{
        "target": JSON.Encode.string(target(architecture)),
        "kind": JSON.Encode.string("oci"),
        "file": JSON.Encode.string(file),
        "size": JSON.Encode.float(size),
        "sha256": JSON.Encode.string(sha256),
      }
      digest->Option.forEach(digest => asset->Dict.set("digest", JSON.Encode.string(digest)))
      JSON.Encode.object(asset)
    })
    ->JSON.Encode.array,
  )
  JSON.Encode.object(fields)
}

let same = (a, b) =>
  a->text("runtime") == b->text("runtime") && a->text("version") == b->text("version")

/** The release's manifest with each entry put in, one of the same version replaced, the rest kept
 * in their order. */
let merged = (existing: option<JSON.t>, ~release, entries: array<JSON.t>) => {
  let kept =
    existing
    ->Option.mapOr([], manifest => manifest->list("runtimes"))
    ->Array.filter(old => !(entries->Array.some(entry => same(old, entry))))
  JSON.Encode.object(
    dict{
      "release": JSON.Encode.string(release),
      "runtimes": JSON.Encode.array([...kept, ...entries]),
    },
  )->JSON.stringify(~space=2) ++ "\n"
}

/** Whether a release's manifest lists the version. */
let lists = (manifest: JSON.t, ~runtime, ~version) =>
  manifest
  ->list("runtimes")
  ->Array.some(entry =>
    entry->text("runtime") == Some(runtime) && entry->text("version") == Some(version)
  )

/** Whether a published release carries the version's archives, so its manifest is the one to
 * read, a draft counting for nothing. */
let holds = (release: JSON.t, ~runtime, ~version) =>
  release->field("draft") != Some(JSON.Encode.bool(true)) &&
    release
    ->list("assets")
    ->Array.some(asset =>
      asset
      ->text("name")
      ->Option.mapOr(false, name => name->String.startsWith(`${runtime}-${version}-`))
    )

/** The head of a release's notes, a table of the versions it holds. */
let header = ["| Runtime | Version | Commit | Image |", "| --- | --- | --- | --- |"]

/** A version's row, upstream's release of it linked, upstream's commit short and linked, then the
 * image linked to its tag on Docker Hub. */
let row = (~runtime, ~version, ~upstream: upstream, ~image) =>
  `| ${runtime} | [${version}](https://github.com/${upstream.repository}/releases/tag/${upstream.tag}) | [\`${upstream.commit->String.slice(
      ~start=0,
      ~end=7,
    )}\`](https://github.com/${upstream.repository}/commit/${upstream.commit}) | [\`${image}:${version}\`](https://hub.docker.com/r/${image}/tags?name=${version}) |`

/** The notes with a row added at the table's end, unless they hold it, the table's head first. */
let appended = (notes, row) => {
  let rows =
    notes
    ->String.split("\n")
    ->Array.map(String.trim)
    ->Array.filter(line => line->String.startsWith("| ") && !(header->Array.includes(line)))
  [...header, ...rows->Array.includes(row) ? rows : [...rows, row]]->Array.join("\n")
}
