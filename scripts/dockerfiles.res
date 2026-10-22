/***
 * What a Dockerfile pins, read and written again, each base image by its tag's digest and the
 * runtime's version with each download's SHA-256.
 */

/** A `FROM` pinned by digest, its lead, image, tag, digest and the rest of the line. */
let from = /^(FROM\s+(?:--platform=\S+\s+)?)([^\s:@]+):([^\s@]+)@(sha256:[0-9a-f]{64})(.*)$/

/** A base image as a Dockerfile pins it, by the line it stands on. */
type base = {index: int, image: string, tag: string, digest: string}

let groups = (pattern, line) =>
  pattern
  ->RegExp.exec(line)
  ->Option.map(result => result->RegExp.Result.matches->Array.map(group => group->Option.getOr("")))

/** Every base image a Dockerfile pins by digest. */
let bases = text =>
  text
  ->String.split("\n")
  ->Array.mapWithIndex((line, index) =>
    switch groups(from, line) {
    | Some([_, image, tag, digest, _]) => Some({index, image, tag, digest})
    | _ => None
    }
  )
  ->Array.filterMap(base => base)

/** The text with each line a base stands on pinned to its digest instead. */
let rebased = (text, digests: dict<string>) =>
  text
  ->String.split("\n")
  ->Array.map(line =>
    switch groups(from, line) {
    | Some([lead, image, tag, old, rest]) =>
      let digest = digests->Dict.get(`${image}:${tag}`)->Option.getOr(old)
      `${lead}${image}:${tag}@${digest}${rest}`
    | _ => line
    }
  )
  ->Array.join("\n")

/** The registry an image is served from and its repository there, Docker Hub's by default. */
let located = image =>
  switch image->String.split("/") {
  | [name] => ("registry-1.docker.io", `library/${name}`)
  | parts =>
    let first = parts->Array.getUnsafe(0)
    if first->String.includes(".") || first->String.includes(":") {
      let host = first == "docker.io" ? "registry-1.docker.io" : first
      (host, parts->Array.slice(~start=1)->Array.join("/"))
    } else {
      ("registry-1.docker.io", image)
    }
  }

/** The token a registry's challenge names, its realm asked with its service and scope. */
let challenged = header => {
  let value = key =>
    RegExp.fromString(`${key}="([^"]*)"`)
    ->RegExp.exec(header)
    ->Option.flatMap(result => result->RegExp.Result.matches->Array.get(0)->Option.flatMap(x => x))
  if !(header->String.toLowerCase->String.startsWith("bearer ")) {
    None
  } else {
    value("realm")->Option.map(realm => {
      let query =
        ["service", "scope"]
        ->Array.filterMap(key =>
          value(key)->Option.map(found => `${key}=${encodeURIComponent(found)}`)
        )
        ->Array.join("&")
      query == "" ? realm : `${realm}?${query}`
    })
  }
}

/** The text with the runtime's version and each architecture's SHA-256 set, by their `ARG`s. */
let repinned = (text, ~prefix, ~version, hashes: dict<string>) =>
  text
  ->String.split("\n")
  ->Array.map(line =>
    switch groups(RegExp.fromString(`^ARG\\s+${prefix}_(VERSION|SHA256_[A-Z0-9]+)=\\S+$`), line) {
    | Some(["VERSION"]) => `ARG ${prefix}_VERSION=${version}`
    | Some([key]) =>
      let architecture = key->String.slice(~start=7)->String.toLowerCase
      switch hashes->Dict.get(architecture) {
      | Some(hash) => `ARG ${prefix}_${key}=${hash}`
      | None => line
      }
    | _ => line
    }
  )
  ->Array.join("\n")

/** The highest version a release names an archive of, from the archives' file names. */
let newest = (names: array<string>, ~runtime) =>
  names
  ->Array.filterMap(name =>
    switch RegExp.fromString(`^${runtime}-(.+)-linux-[a-z0-9_]+\\.tar$`)->RegExp.exec(name) {
    | Some(result) => result->RegExp.Result.matches->Array.get(0)->Option.flatMap(x => x)
    | None => None
    }
  )
  ->Array.filterMap(version => Upstream.numbers(version)->Option.map(n => (n, version)))
  ->Array.toSorted(((a, _), (b, _)) => Int.toFloat(Upstream.compare(b, a)))
  ->Array.get(0)
  ->Option.map(((_, version)) => version)
