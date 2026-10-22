/***
 * `node scripts/pins.res.mjs [--dry-run]`, run by hand from update, moving each Dockerfile's
 * runtime to the newest version released here, its base images moved by the workspace's images.res.
 */
let dry = Host.argv->Array.includes("--dry-run")
let root = Host.cwd()

let reached = async (url, init) =>
  switch await Host.fetch(url, init) {
  | response => Ok(response)
  | exception JsExn(e) => Error(`${url}: ${e->JsExn.message->Option.getOr("not reached")}`)
  }

/** The newest version of `runtime` a published release here lists in its manifest, from what the
 * workspace's scripts/release reads of every one. */
let released = (listed: array<JSON.t>, ~runtime) =>
  listed
  ->Array.filter(entry => entry->Image.text("name") == Some(runtime))
  ->Array.flatMap(entry => entry->Image.list("assets")->Array.filterMap(a => a->Image.text("file")))
  ->Dockerfiles.newest(~runtime)

/** Each architecture's download of `version` hashed, as the Dockerfile's `ADD` fetches it. */
let hashes = async (pin: Image.pin, ~prefix, ~version) => {
  let found = Dict.make()
  let failed = ref(None)
  for index in 0 to pin.fetched->Dict.keysToArray->Array.length - 1 {
    let architecture = pin.fetched->Dict.keysToArray->Array.getUnsafe(index)
    let {address}: Image.fetched = pin.fetched->Dict.getUnsafe(architecture)
    let url = address->Image.at(~prefix, ~version)
    switch await reached(url, {headers: dict{"user-agent": "monoflake-runtime"}}) {
    | Ok(response) if response->Host.ok =>
      let bytes = Uint8Array.fromBuffer(await response->Host.arrayBuffer)
      found->Dict.set(
        architecture,
        Host.createHash("sha256")->Host.update(bytes)->Host.digest("hex"),
      )
    | Ok(response) => failed := Some(`${url} answered ${response->Host.status->Int.toString}`)
    | Error(why) => failed := Some(why)
    }
  }
  switch failed.contents {
  | Some(why) => Error(why)
  | None => Ok(found)
  }
}

let main = async () => {
  let runtimes =
    Host.readdir(`${root}/images`)->Array.filter(name =>
      Host.existsSync(`${root}/images/${name}/Dockerfile`)
    )
  let files = runtimes->Array.map(name => (name, `${root}/images/${name}/Dockerfile`))
  let texts = Dict.fromArray(files->Array.map(((name, file)) => (name, Host.readFileSync(file))))
  let failed = ref(false)

  let listed = Released.listed(~root)
  for index in 0 to files->Array.length - 1 {
    let (name, file) = files->Array.getUnsafe(index)
    let prefix = name->String.toUpperCase
    let text = texts->Dict.getUnsafe(name)
    let based = text
    let pinned = switch (Image.read(text, ~prefix), listed) {
    | (Error(why), _) | (_, Error(why)) =>
      Console.log(`pins: ${name}, its version not moved: ${why}`)
      failed := true
      based
    | (Ok(pin), Ok(listed)) =>
      switch released(listed, ~runtime=name) {
      | None =>
        Console.log(`pins: ${name} ${pin.version}, nothing released here to move to`)
        based
      | Some(version) if version == pin.version =>
        Console.log(`pins: ${name} ${version}, the newest released here`)
        based
      | Some(version) =>
        switch await hashes(pin, ~prefix, ~version) {
        | Error(why) =>
          Console.log(`pins: ${name} ${version}, its downloads could not be hashed: ${why}`)
          failed := true
          based
        | Ok(found) =>
          Console.log(`pins: ${name} ${pin.version} -> ${version}, as released here`)
          Dockerfiles.repinned(based, ~prefix, ~version, found)
        }
      }
    }
    if pinned != text && !dry {
      Host.writeFileSync(file, pinned)
    }
  }
  Host.exit(failed.contents ? 1 : 0)
}

main()->ignore
