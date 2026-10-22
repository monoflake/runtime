/***
 * `node .github/publish/publish.res.mjs [--dry-run]`, releasing each runtime upstream released past
 * the delay that no tag here holds, to this repository and to Docker Hub from one build, the dry
 * run building nothing.
 */
let refuse = reason => {
  Console.error(`publish: ${reason}`)
  Host.exit(1)
}

/** Where a runtime's versions are read, npm's package per architecture or GitHub's releases. */
type source = Npm(array<string>) | GitHub(string)

/** Each runtime, its `ARG` prefix, where its versions are read, and the GitHub repository whose
 * release of a version its notes link to. */
type runtime = {name: string, prefix: string, source: source, upstream: string}

let runtimes = [
  {
    name: "workerd",
    prefix: "WORKERD",
    source: Npm(["workerd-linux-64", "workerd-linux-arm64"]),
    upstream: "cloudflare/workerd",
  },
  {
    name: "wasmtime",
    prefix: "WASMTIME",
    source: GitHub("bytecodealliance/wasmtime"),
    upstream: "bytecodealliance/wasmtime",
  },
]

let root = Host.cwd()
let dry = Host.argv->Array.includes("--dry-run")

/** The Docker Hub account the images are pushed under, the author's own, RFC m7rkq. */
let namespace = "canmi"
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

/** A command printed with the variables it is given, then run unless the run is dry. */
let run = (command, args, ~cwd=root, ~env=[]) => {
  let given = env->Array.map(((key, value)) => `${key}=${shown(value)}`)
  Console.log(`  $ ${[...given, command, ...args->Array.map(shown)]->Array.join(" ")}`)
  let env = Dict.fromArray([...Host.env->Dict.toArray, ...env])
  dry
    ? Ok()
    : switch Host.spawnSync(command, args, {cwd, stdio: "inherit", env}).status->Nullable.toOption {
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

/** The build arguments a version is built with, its number and each download's SHA-256. */
let buildArgs = (prefix, version, hashes) =>
  [
    (`${prefix}_VERSION`, version),
    ...hashes
    ->Dict.toArray
    ->Array.map(((architecture, hash)) => (
      `${prefix}_SHA256_${architecture->String.toUpperCase}`,
      hash,
    )),
  ]

/** The digest a target's build pushed, as bake's metadata file records it under the target. */
let digestOf = (path, name) =>
  readFile(path)->Result.flatMap(text =>
    switch JSON.parseOrThrow(text)
    ->Upstream.field(name)
    ->Option.flatMap(target => target->Upstream.text("containerimage.digest")) {
    | Some(digest) => Ok(digest)
    | None => Error(`${path} records no containerimage.digest`)
    | exception JsExn(_) => Error(`${path} is not JSON`)
    }
  )

/** Each architecture built once into its archive and its image pushed by digest, the image then
 * tagged over both, and the release drafted with the archives and their manifest, published last
 * so its tag stands only for a release whose assets are all up. */
let release = ({name, prefix, upstream}, pin, version, hashes) => {
  let tag = Image.tag(~runtime=name, ~version)
  let out = `${root}/dist/${tag}`
  let image = `docker.io/${namespace}/${name}`
  let archive = architecture => `${out}/${Image.archive(~runtime=name, ~version, ~architecture)}`
  let metadata = architecture => `${out}/${architecture}.json`
  let set = (key, value) => ["--set", `${name}.${key}=${value}`]
  let args =
    buildArgs(prefix, version, hashes)->Array.flatMap(((key, value)) => set(`args.${key}`, value))
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
          ...args,
          "--metadata-file",
          metadata(architecture),
          name,
        ],
        ~cwd=`${root}/images`,
        ~env=[("ARCHIVE", archive(architecture)), ("IMAGE", image)],
      )
    )
  )
  ->Result.flatMap(() =>
    architectures(pin)->Array.reduce(Ok([]), (read, architecture) =>
      read->Result.flatMap(
        digests =>
          (
            dry ? Ok(`<${architecture} digest>`) : digestOf(metadata(architecture), name)
          )->Result.map(digest => [...digests, (architecture, digest)]),
      )
    )
  )
  ->Result.flatMap(digests =>
    run(
      "docker",
      Image.tagged(~image, ~version, digests->Array.map(((_, digest)) => digest)),
    )->Result.map(() => digests)
  )
  ->Result.flatMap(digests => {
    let manifest = `${out}/manifest.json`
    if !dry {
      let assets = digests->Array.map(((architecture, digest)) => {
        let bytes = Host.readBytes(archive(architecture))
        let asset: Image.asset = {
          file: Image.archive(~runtime=name, ~version, ~architecture),
          size: bytes->TypedArray.length->Int.toFloat,
          sha256: sha256(bytes),
          digest,
        }
        (architecture, asset)
      })
      Host.writeFileSync(
        manifest,
        Image.manifest(
          ~runtime=name,
          ~version,
          ~sha=?Host.env->Dict.get("GITHUB_SHA"),
          Dict.fromArray(assets),
        ),
      )
    }
    run(
      "gh",
      [
        "release",
        "create",
        tag,
        "--repo",
        repository,
        "--draft",
        "--title",
        tag,
        "--notes",
        Image.notes(
          ~runtime=name,
          ~version,
          ~upstream,
          ~image=`${namespace}/${name}`,
          architectures(pin),
        ),
        ...architectures(pin)->Array.map(archive),
        manifest,
      ],
    )->Result.flatMap(() =>
      run("gh", ["release", "edit", tag, "--repo", repository, "--draft=false"])
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
| _ => refuse("node .github/publish/publish.res.mjs [--dry-run]")
}
