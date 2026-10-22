/***
 * The runtime's version a Dockerfile pins with each download's SHA-256, written again, and the
 * newest version a release here holds; its base images are the workspace's scripts/deps/images.res.
 */

let groups = (pattern, line) =>
  pattern
  ->RegExp.exec(line)
  ->Option.map(result => result->RegExp.Result.matches->Array.map(group => group->Option.getOr("")))

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
