/***
 * `node scripts/pins.res.mjs [--dry-run]`, run by hand from update, moving each Dockerfile's base
 * images to the digest their tag names now and its runtime to the newest version released here.
 */
let dry = Host.argv->Array.includes("--dry-run")
let root = Host.cwd()
let repository = "monoflake/runtime"
let token = switch Host.env->Dict.get("GITHUB_TOKEN") {
| Some(token) => Some(token)
| None => Host.env->Dict.get("GH_TOKEN")
}

/** The index and manifest types a registry is asked to answer a tag with. */
let accepted = [
  "application/vnd.oci.image.index.v1+json",
  "application/vnd.docker.distribution.manifest.list.v2+json",
  "application/vnd.oci.image.manifest.v1+json",
  "application/vnd.docker.distribution.manifest.v2+json",
]->Array.join(", ")

let reached = async (url, init) =>
  switch await Host.fetch(url, init) {
  | response => Ok(response)
  | exception JsExn(e) => Error(`${url}: ${e->JsExn.message->Option.getOr("not reached")}`)
  }

/** The digest a tag names now, asked by HEAD, so nothing is pulled, with the anonymous token a
 * registry's challenge asks for. */
let digestOf = async (image, tag) => {
  let (host, name) = Dockerfiles.located(image)
  let url = `https://${host}/v2/${name}/manifests/${tag}`
  let ask = async bearer => {
    let headers = dict{"accept": accepted}
    bearer->Option.forEach(bearer => headers->Dict.set("authorization", `Bearer ${bearer}`))
    await reached(url, {method: "HEAD", headers})
  }
  let found = response =>
    switch response->Host.headers->Host.header("docker-content-digest")->Nullable.toOption {
    | Some(digest) if response->Host.ok => Ok(digest)
    | _ => Error(`${url} answered ${response->Host.status->Int.toString} with no digest`)
    }
  switch await ask(None) {
  | Error(why) => Error(why)
  | Ok(response) if response->Host.status != 401 => found(response)
  | Ok(response) =>
    switch response
    ->Host.headers
    ->Host.header("www-authenticate")
    ->Nullable.toOption
    ->Option.flatMap(Dockerfiles.challenged) {
    | None => Error(`${url} asked for a token it did not say how to get`)
    | Some(realm) =>
      switch await reached(realm, {headers: dict{}}) {
      | Error(why) => Error(why)
      | Ok(answer) =>
        let text = await answer->Host.text
        switch JSON.parseOrThrow(text) {
        | json =>
          switch (json->Image.text("token"), json->Image.text("access_token")) {
          | (Some(bearer), _) | (None, Some(bearer)) =>
            switch await ask(Some(bearer)) {
            | Ok(response) => found(response)
            | Error(why) => Error(why)
            }
          | (None, None) => Error(`${realm} gave no token`)
          }
        | exception JsExn(_) => Error(`${realm} answered with no JSON`)
        }
      }
    }
  }
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

  // Each base image's tag asked once, though several stages pin it.
  let digests = Dict.make()
  let tags =
    texts
    ->Dict.valuesToArray
    ->Array.flatMap(Dockerfiles.bases)
    ->Array.map(({image, tag}) => `${image}:${tag}`)
    ->Array.reduce([], (seen, key) => seen->Array.includes(key) ? seen : [...seen, key])
  for index in 0 to tags->Array.length - 1 {
    let key = tags->Array.getUnsafe(index)
    let at = key->String.lastIndexOf(":")
    let (image, tag) = (key->String.slice(~start=0, ~end=at), key->String.slice(~start=at + 1))
    switch await digestOf(image, tag) {
    | Ok(digest) => digests->Dict.set(key, digest)
    | Error(why) =>
      Console.log(`pins: ${key}, its digest could not be read: ${why}`)
      failed := true
    }
  }

  let releases = await github(`https://api.github.com/repos/${repository}/releases?per_page=100`)
  for index in 0 to files->Array.length - 1 {
    let (name, file) = files->Array.getUnsafe(index)
    let prefix = name->String.toUpperCase
    let text = texts->Dict.getUnsafe(name)
    Dockerfiles.bases(text)
    ->Array.reduce([], (seen, base) =>
      seen->Array.some(({image, tag}: Dockerfiles.base) => image == base.image && tag == base.tag)
        ? seen
        : [...seen, base]
    )
    ->Array.forEach(({image, tag, digest}) =>
      switch digests->Dict.get(`${image}:${tag}`) {
      | Some(now) if now != digest =>
        Console.log(`pins: ${name} ${image}:${tag} ${digest} -> ${now}`)
      | Some(_) => Console.log(`pins: ${name} ${image}:${tag}, its tag's digest still`)
      | None => ()
      }
    )
    let based = Dockerfiles.rebased(text, digests)
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
