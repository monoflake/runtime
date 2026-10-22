/***
 * `node scripts/pins.res.mjs [--dry-run]`, run by hand from update, moving each Dockerfile's runtime
 * to the newest version released here, its base images moved by the workspace's images.res.
 */
let dry = Host.argv->Array.includes("--dry-run")
let root = Host.cwd()
let repository = "monoflake/runtime"
let token = switch Host.env->Dict.get("GITHUB_TOKEN") {
| Some(token) => Some(token)
| None => Host.env->Dict.get("GH_TOKEN")
}

let reached = async (url, init) =>
  switch await Host.fetch(url, init) {
  | response => Ok(response)
  | exception JsExn(e) => Error(`${url}: ${e->JsExn.message->Option.getOr("not reached")}`)
  }

/** A JSON document from GitHub, with the token where one is set. */
let github = async url => {
  let headers = dict{"accept": "application/vnd.github+json", "user-agent": "monoflake-runtime"}
  token->Option.forEach(token => headers->Dict.set("authorization", `Bearer ${token}`))
  switch await reached(url, {headers: headers}) {
  | Error(why) => Error(why)
  | Ok(response) if !(response->Host.ok) =>
    Error(`${url} answered ${response->Host.status->Int.toString}`)
  | Ok(response) =>
    let text = await response->Host.text
    try Ok(JSON.parseOrThrow(text)) catch {
    | JsExn(_) => Error(`${url} is not JSON`)
    }
  }
}

/** The newest version of `runtime` a published release here lists in its manifest. */
let released = async (releases, ~runtime) => {
  let published =
    releases->Array.filter(release => release->Image.field("draft") != Some(JSON.Encode.bool(true)))
  let names =
    published->Array.flatMap(release =>
      release->Image.list("assets")->Array.filterMap(asset => asset->Image.text("name"))
    )
  switch Dockerfiles.newest(names, ~runtime) {
  | None => Ok(None)
  | Some(version) =>
    switch published->Array.find(release => Image.holds(release, ~runtime, ~version)) {
    | None => Ok(None)
    | Some(release) =>
      switch release
      ->Image.list("assets")
      ->Array.find(asset => asset->Image.text("name") == Some(Image.manifestFile))
      ->Option.flatMap(asset => asset->Image.text("browser_download_url")) {
      | None => Ok(None)
      | Some(url) =>
        (await github(url))->Result.map(manifest =>
          Image.lists(manifest, ~runtime, ~version) ? Some(version) : None
        )
      }
    }
  }
}

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

  let releases = await github(`https://api.github.com/repos/${repository}/releases?per_page=100`)
  for index in 0 to files->Array.length - 1 {
    let (name, file) = files->Array.getUnsafe(index)
    let prefix = name->String.toUpperCase
    let text = texts->Dict.getUnsafe(name)
    let based = text
    let pinned = switch (Image.read(text, ~prefix), releases) {
    | (Error(why), _) | (_, Error(why)) =>
      Console.log(`pins: ${name}, its version not moved: ${why}`)
      failed := true
      based
    | (Ok(pin), Ok(releases)) =>
      switch await released(releases->JSON.Decode.array->Option.getOr([]), ~runtime=name) {
      | Error(why) =>
        Console.log(`pins: ${name}, its version not moved: ${why}`)
        failed := true
        based
      | Ok(None) =>
        Console.log(`pins: ${name} ${pin.version}, nothing released here to move to`)
        based
      | Ok(Some(version)) if version == pin.version =>
        Console.log(`pins: ${name} ${version}, the newest released here`)
        based
      | Ok(Some(version)) =>
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
