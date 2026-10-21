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

/** The release's tag, which says whether the version was built already. */
let tag = (~runtime, ~version) => `${runtime}-${version}`

/** An architecture's archive, as the release names the asset. */
let archive = (~runtime, ~version, ~architecture) => `${runtime}-${version}-${architecture}.tar`

/** One archive as the manifest lists it. */
type asset = {name: string, size: float, sha256: string}

/** The manifest a release carries, each architecture's asset with its size and SHA-256. */
let manifest = (~runtime, ~version, assets: dict<asset>) =>
  JSON.Encode.object(
    dict{
      "runtime": JSON.Encode.string(runtime),
      "version": JSON.Encode.string(version),
      "archives": JSON.Encode.object(
        assets->Dict.mapValues(({name, size, sha256}) =>
          JSON.Encode.object(
            dict{
              "name": JSON.Encode.string(name),
              "size": JSON.Encode.float(size),
              "sha256": JSON.Encode.string(sha256),
            },
          )
        ),
      ),
    },
  )->JSON.stringify(~space=2) ++ "\n"
