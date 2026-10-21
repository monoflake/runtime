/***
 * `node scripts/publish.res.mjs [--dry-run]`, building and releasing each runtime upstream released
 * past the delay that no tag here holds yet, the dry run building nothing.
 */
let refuse = reason => {
  Console.error(`publish: ${reason}`)
  Host.exit(1)
}

/** Where a runtime's versions are read, npm's package per architecture or GitHub's releases. */
type source = Npm(array<string>) | GitHub(string)

type runtime = {name: string, prefix: string, source: source}

let runtimes = [
  {name: "workerd", prefix: "WORKERD", source: Npm(["workerd-linux-64", "workerd-linux-arm64"])},
  {name: "wasmtime", prefix: "WASMTIME", source: GitHub("bytecodealliance/wasmtime")},
]

let root = Host.cwd()
let dry = Host.argv->Array.includes("--dry-run")
let repository = Host.env->Dict.get("GITHUB_REPOSITORY")->Option.getOr("monoflake/runtime")
let token = switch Host.env->Dict.get("GITHUB_TOKEN") {
| Some(token) => Some(token)
| None => Host.env->Dict.get("GH_TOKEN")
}

let headers = url => {
  let headers = dict{"user-agent": "monoflake-runtime"}
  if url->String.startsWith("https://api.github.com/") {
    headers->Dict.set("accept", "application/vnd.github+json")
    token->Option.forEach(token => headers->Dict.set("authorization", `Bearer ${token}`))
  }
  headers
}

let fetched = async (url, read) =>
  switch await Host.fetch(url, {headers: headers(url)}) {
  | response if response->Host.ok => Ok(await read(response))
  | response => Error(`${url} answered ${response->Host.status->Int.toString}`)
  | exception JsExn(e) => Error(`${url}: ${e->JsExn.message->Option.getOr("not reached")}`)
  }

let sha256 = bytes => Host.createHash("sha256")->Host.update(bytes)->Host.digest("hex")

let readFile = path =>
  try Ok(Host.readFileSync(path)) catch {
  | JsExn(e) => Error(`${path}: ${e->JsExn.message->Option.getOr("not read")}`)
  }

/** Each of `items` through `step` in turn, stopping at the first error. */
let rec each = async (items, step, ~done=[]) =>
  switch items {
  | [] => Ok(done)
  | _ =>
    switch await step(items->Array.getUnsafe(0)) {
    | Ok(value) => await each(items->Array.slice(~start=1), step, ~done=[...done, value])
    | Error(why) => Error(why)
    }
  }

/** What upstream published, and the bound npm's `latest` tag sets. */
let published = async source =>
  switch source {
  | Npm(packages) =>
    (
      await each(packages, async name =>
        (
          await fetched(`https://registry.npmjs.org/@cloudflare/${name}`, Host.text)
        )->Result.flatMap(Upstream.npm)
      )
    )->Result.map(documents => (
      documents->Array.get(0)->Option.map(((latest, _)) => latest),
      documents->Array.map(((_, list)) => list)->Upstream.everywhere,
    ))
  | GitHub(repo) =>
    (await fetched(`https://api.github.com/repos/${repo}/releases?per_page=100`, Host.text))
    ->Result.flatMap(Upstream.github)
    ->Result.map(list => (None, list))
  }

/** Whether this repository holds the tag, which a release here creates once its assets are up. */
let released = async tag => {
  let url = `https://api.github.com/repos/${repository}/git/ref/tags/${tag}`
  switch await Host.fetch(url, {headers: headers(url)}) {
  | response if response->Host.ok => Ok(true)
  | response if response->Host.status == 404 => Ok(false)
  | response => Error(`${url} answered ${response->Host.status->Int.toString}`)
  | exception JsExn(e) => Error(`${url}: ${e->JsExn.message->Option.getOr("not reached")}`)
  }
}

let shown = arg => arg->String.includes(" ") ? `'${arg}'` : arg

/** A command printed, then run unless the run is dry. */
let run = (command, args, ~cwd=root) => {
  Console.log(`  $ ${[command, ...args]->Array.map(shown)->Array.join(" ")}`)
  dry
    ? Ok()
    : switch Host.spawnSync(command, args, {cwd, stdio: "inherit"}).status->Nullable.toOption {
      | Some(0) => Ok()
      | _ => Error(`${command} ${args->Array.slice(~start=0, ~end=2)->Array.join(" ")} failed`)
      }
}

let architectures = (pin: Image.pin) =>
  pin.fetched->Dict.keysToArray->Array.toSorted(String.compare)

/** Each architecture's download of `version` and its SHA-256, the pinned hash held where the
 * version is the pinned one. */
let hashes = async ({name, prefix}, pin: Image.pin, version) =>
  (
    await each(architectures(pin), async architecture => {
      let {hash, address}: Image.fetched = pin.fetched->Dict.getUnsafe(architecture)
      let address = address->Image.at(~prefix, ~version)
      switch await fetched(address, Host.arrayBuffer) {
      | Ok(bytes) =>
        let found = sha256(Uint8Array.fromBuffer(bytes))
        Console.log(`  ${architecture} ${address}`)
        Console.log(`    sha256 ${found}`)
        version == pin.version && found != hash
          ? Error(`${name} ${version} ${architecture} hashes to ${found}, not the pinned ${hash}`)
          : Ok((architecture, found))
      | Error(why) => Error(why)
      }
    })
  )->Result.map(Dict.fromArray)

/** Every architecture's archive built, then the release made of them and their manifest. */
let release = ({name, prefix}, pin, version, hashes) => {
  let tag = Image.tag(~runtime=name, ~version)
  let out = `${root}/dist/${tag}`
  let archive = architecture => `${out}/${Image.archive(~runtime=name, ~version, ~architecture)}`
  let set = (key, value) => ["--set", `${name}.${key}=${value}`]
  let args = [
    ...set(`args.${prefix}_VERSION`, version),
    ...hashes
    ->Dict.toArray
    ->Array.flatMap(((architecture, hash)) =>
      set(`args.${prefix}_SHA256_${architecture->String.toUpperCase}`, hash)
    ),
  ]
  if !dry {
    Host.mkdirSync(out, {recursive: true})
  }
  architectures(pin)
  ->Array.reduce(Ok(), (built, architecture) =>
    built->Result.flatMap(() =>
      run(
        "docker",
        [
          "buildx",
          "bake",
          "--file",
          "docker-bake.hcl",
          "--provenance=false",
          ...set("platform", `linux/${architecture}`),
          ...set("tags", `${name}:${version}`),
          ...set("output", `type=oci,dest=${archive(architecture)}`),
          ...args,
          name,
        ],
        ~cwd=`${root}/images`,
      )
    )
  )
  ->Result.flatMap(() => {
    let manifest = `${out}/manifest.json`
    if !dry {
      let assets = architectures(pin)->Array.map(architecture => {
        let bytes = Host.readBytes(archive(architecture))
        let asset: Image.asset = {
          name: Image.archive(~runtime=name, ~version, ~architecture),
          size: bytes->TypedArray.length->Int.toFloat,
          sha256: sha256(bytes),
        }
        (architecture, asset)
      })
      Host.writeFileSync(manifest, Image.manifest(~runtime=name, ~version, Dict.fromArray(assets)))
    }
    run(
      "gh",
      [
        "release",
        "create",
        tag,
        "--repo",
        repository,
        "--title",
        tag,
        "--notes",
        `${name} ${version} as upstream released it, an OCI archive per architecture.`,
        ...architectures(pin)->Array.map(archive),
        manifest,
      ],
    )
  })
}

let publish = async (runtime, ~delay) => {
  let {name, prefix, source} = runtime
  let file = `images/${name}/Dockerfile`
  switch readFile(file)->Result.flatMap(text => Image.read(text, ~prefix)) {
  | Error(why) => Error(`${file}: ${why}`)
  | Ok(pin) =>
    switch await published(source) {
    | Error(why) => Error(why)
    | Ok((bound, list)) =>
      let {take, held}: Upstream.chosen = Upstream.choose(list, ~bound?, ~delay, ~now=Date.now())
      Console.log(`${name}:`)
      Console.log(`  the Dockerfile pins ${pin.version}`)
      if held != [] {
        Console.log(
          `  held back by minimumReleaseAge, ${delay->Int.toString} minutes: ${held->Array.join(
              ", ",
            )}`,
        )
      }
      switch take {
      | None =>
        Console.log("  nothing past the delay")
        Ok()
      | Some(version) =>
        let tag = Image.tag(~runtime=name, ~version)
        switch await released(tag) {
        | Error(why) => Error(why)
        | Ok(true) =>
          Console.log(`  ${version}, released already as ${tag}`)
          Ok()
        | Ok(false) =>
          Console.log(`  ${version}, which ${repository} has no tag ${tag} for`)
          (await hashes(runtime, pin, version))->Result.flatMap(hashes =>
            release(runtime, pin, version, hashes)
          )
        }
      }
    }
  }
}

switch Host.argv->Array.slice(~start=2) {
| [] | ["--dry-run"] =>
  switch readFile("pnpm-workspace.yaml")->Result.flatMap(Upstream.delay) {
  | Error(why) => refuse(`pnpm-workspace.yaml: ${why}`)
  | Ok(delay) =>
    // One runtime failing is its own, so the other is still published.
    let failed = (
      await each(runtimes, async runtime => Ok(
        switch await publish(runtime, ~delay) {
        | Ok() => None
        | Error(why) =>
          Console.error(`publish: ${why}`)
          Some(runtime.name)
        },
      ))
    )->Result.mapOr([], found => found->Array.filterMap(x => x))
    if failed != [] {
      refuse(`not published: ${failed->Array.join(", ")}`)
    }
  }
| _ => refuse("node scripts/publish.res.mjs [--dry-run]")
}
