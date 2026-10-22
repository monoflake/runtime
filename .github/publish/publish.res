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

/** A version built, its archives, its manifest and its line in the day's notes. */
type built = {archives: array<string>, manifest: string, line: string}

/** Each architecture built once into its archive and its image pushed by digest, the image then
 * tagged over both, and the version's manifest written beside its archives. */
let build = ({name, prefix, upstream}, pin, version, hashes) => {
  let out = `${root}/dist/${name}-${version}`
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
          // Bake writes outside its own directory only where it is let, the archive's alone.
          `--allow=fs.write=${out}`,
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
        ~env=[("ARCHIVE", archive(architecture)), ("IMAGE", image), ("VERSION", version)],
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
  ->Result.map(digests => {
    let manifest = `${out}/${Image.entry(~runtime=name, ~version)}`
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
    {
      archives: architectures(pin)->Array.map(archive),
      manifest,
      line: Image.line(~runtime=name, ~version, ~upstream, ~image=`${namespace}/${name}`),
    }
  })
}

/** Every release here, a page of a hundred at a time, drafts among them. */
let releases = async () => {
  let rec page = async (n, found) =>
    switch await fetched(
      `https://api.github.com/repos/${repository}/releases?per_page=100&page=${n->Int.toString}`,
      Host.text,
    ) {
    | Error(why) => Error(why)
    | Ok(text) =>
      switch JSON.parseOrThrow(text)->JSON.Decode.array {
      | Some([]) => Ok(found)
      | Some(list) => await page(n + 1, [...found, ...list])
      | None => Error(`${repository}'s releases are not a list`)
      | exception JsExn(_) => Error(`${repository}'s releases are not JSON`)
      }
    }
  await page(1, [])
}

/** The version upstream released past the delay built, unless a release here holds it whole. */
let publish = async (runtime, ~delay, ~releases) => {
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
        Ok(None)
      | Some(version) if Image.released(releases, ~runtime=name, ~version) =>
        Console.log(`  ${version}, released here already`)
        Ok(None)
      | Some(version) =>
        Console.log(`  ${version}, which no release here holds`)
        (await hashes(runtime, pin, version))
        ->Result.flatMap(hashes => build(runtime, pin, version, hashes))
        ->Result.map(built => Some(built))
      }
    }
  }
}

/** A field of a release, as text. */
let text = (release, key) =>
  release
  ->JSON.Decode.object
  ->Option.flatMap(o => o->Dict.get(key))
  ->Option.flatMap(JSON.Decode.string)

/** What was built released under the UTC day, a new release drafted whole and published last, or
 * the day's published one added to, each manifest uploaded after its archives and its line. */
let release = (builds, ~releases) => {
  let tag = Image.day(Date.now())
  let named = releases->Array.filter(release => release->text("tag_name") == Some(tag))
  let published =
    named->Array.find(release =>
      release->JSON.Decode.object->Option.flatMap(o => o->Dict.get("draft")) !=
        Some(JSON.Encode.bool(true))
    )
  let gh = args => run("gh", [...args, "--repo", repository])
  switch published {
  | Some(release) =>
    Console.log(`release ${tag}, added to`)
    let notes =
      builds->Array.reduce(release->text("body")->Option.getOr(""), (notes, {line}) =>
        Image.appended(notes, line)
      )
    builds
    ->Array.reduce(Ok(), (done, {archives}) =>
      done->Result.flatMap(() => gh(["release", "upload", tag, ...archives, "--clobber"]))
    )
    ->Result.flatMap(() => gh(["release", "edit", tag, "--notes", notes]))
    ->Result.flatMap(() =>
      builds->Array.reduce(Ok(), (done, {manifest}) =>
        done->Result.flatMap(() => gh(["release", "upload", tag, manifest, "--clobber"]))
      )
    )
  | None =>
    Console.log(`release ${tag}, new`)
    // A draft a failed run left under the day's name is put aside, so one release takes the name.
    named
    ->Array.reduce(Ok(), (done, _) =>
      done->Result.flatMap(() => gh(["release", "delete", tag, "--yes"]))
    )
    ->Result.flatMap(() =>
      gh(
        [
          "release",
          "create",
          tag,
          "--draft",
          "--title",
          tag,
          "--notes",
          builds->Array.map(({line}) => line)->Array.join("\n"),
          ...builds->Array.flatMap(({archives, manifest}) => [...archives, manifest]),
        ],
      )
    )
    ->Result.flatMap(() => gh(["release", "edit", tag, "--draft=false"]))
  }
}

switch Host.argv->Array.slice(~start=2) {
| [] | ["--dry-run"] =>
  switch readFile("pnpm-workspace.yaml")->Result.flatMap(Upstream.delay) {
  | Error(why) => refuse(`pnpm-workspace.yaml: ${why}`)
  | Ok(delay) =>
    switch await releases() {
    | Error(why) => refuse(why)
    | Ok(releases) =>
      // One runtime failing is its own, so the other is still built and released.
      let outcomes =
        (
          await each(runtimes, async runtime => Ok((
            runtime.name,
            await publish(runtime, ~delay, ~releases),
          )))
        )->Result.getOr([])
      outcomes->Array.forEach(((name, outcome)) =>
        switch outcome {
        | Error(why) => Console.error(`publish: ${name}: ${why}`)
        | Ok(_) => ()
        }
      )
      let builds = outcomes->Array.filterMap(((_, outcome)) =>
        switch outcome {
        | Ok(Some(built)) => Some(built)
        | Ok(None) | Error(_) => None
        }
      )
      let released = builds == [] ? Ok() : release(builds, ~releases)
      let failed =
        outcomes->Array.filterMap(((name, outcome)) => Result.isError(outcome) ? Some(name) : None)
      switch released {
      | Error(why) => refuse(`not released: ${why}`)
      | Ok() if failed != [] => refuse(`not published: ${failed->Array.join(", ")}`)
      | Ok() => ()
      }
    }
  }
| _ => refuse("node .github/publish/publish.res.mjs [--dry-run]")
}
