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

/** A response read as JSON. */
let json = async url =>
  (await fetched(url, Host.text))->Result.flatMap(text =>
    try Ok(JSON.parseOrThrow(text)) catch {
    | JsExn(_) => Error(`${url} is not JSON`)
    }
  )

/** The commit upstream's tag names, an annotated tag followed to the commit it points at. */
let commitOf = async (repository, tag) => {
  let object = found => found->Image.field("object")->Option.getOr(JSON.Encode.null)
  let rec follow = async target =>
    switch (target->Image.text("type"), target->Image.text("sha")) {
    | (Some("commit"), Some(sha)) => Ok(sha)
    | (Some("tag"), Some(sha)) =>
      switch await json(`https://api.github.com/repos/${repository}/git/tags/${sha}`) {
      | Ok(found) => await follow(object(found))
      | Error(why) => Error(why)
      }
    | _ => Error(`${repository}'s ${tag} names no commit`)
    }
  switch await json(`https://api.github.com/repos/${repository}/git/ref/tags/${tag}`) {
  | Ok(found) => await follow(object(found))
  | Error(why) => Error(why)
  }
}

/** A release's manifest as it was uploaded, or none where the release carries none. */
let manifestOf = async release =>
  switch release
  ->Image.list("assets")
  ->Array.find(asset => asset->Image.text("name") == Some(Image.manifestFile))
  ->Option.flatMap(asset => asset->Image.text("browser_download_url")) {
  | None => Ok(None)
  | Some(url) => (await json(url))->Result.map(manifest => Some(manifest))
  }

/** Whether a published release here lists the version in its manifest, only those carrying its
 * archives read. */
let releasedHere = async (releases, ~runtime, ~version) =>
  await each(
    releases->Array.filter(release => Image.holds(release, ~runtime, ~version)),
    manifestOf,
  )->Promise.thenResolve(read =>
    read->Result.map(manifests =>
      manifests->Array.some(
        manifest =>
          manifest->Option.mapOr(false, manifest => Image.lists(manifest, ~runtime, ~version)),
      )
    )
  )

/** A version built, its archives, its entry in the day's manifest and its row in the notes. */
type built = {archives: array<string>, entry: JSON.t, row: string}

/** Each architecture built once into its archive and its image pushed by digest, the image then
 * tagged over both, and the version's entry made for the day's manifest. */
let build = ({name, prefix}, pin, version, hashes, upstream: Image.upstream) => {
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
    let assets = digests->Array.map(((architecture, digest)) => {
      let file = Image.archive(~runtime=name, ~version, ~architecture)
      let bytes = dry ? Uint8Array.fromLength(0) : Host.readBytes(archive(architecture))
      let asset: Image.asset = {
        file,
        size: bytes->TypedArray.length->Int.toFloat,
        sha256: sha256(bytes),
        digest,
      }
      (architecture, asset)
    })
    {
      archives: architectures(pin)->Array.map(archive),
      entry: Image.entry(
        ~runtime=name,
        ~version,
        ~commit=?Host.env->Dict.get("GITHUB_SHA"),
        ~upstream,
        Dict.fromArray(assets),
      ),
      row: Image.row(~runtime=name, ~version, ~upstream, ~image=`${namespace}/${name}`),
    }
  })
}

/** Every release here, a page of a hundred at a time, drafts among them. */
let releases = async () => {
  let rec page = async (n, found) =>
    switch await json(
      `https://api.github.com/repos/${repository}/releases?per_page=100&page=${n->Int.toString}`,
    ) {
    | Error(why) => Error(why)
    | Ok(listed) =>
      switch listed->JSON.Decode.array {
      | Some([]) => Ok(found)
      | Some(list) => await page(n + 1, [...found, ...list])
      | None => Error(`${repository}'s releases are not a list`)
      }
    }
  await page(1, [])
}

/** The version upstream released past the delay built, unless a release here lists it. */
let publish = async (runtime, ~delay, ~releases) => {
  let {name, prefix, source, upstream} = runtime
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
      | Some(version) =>
        switch await releasedHere(releases, ~runtime=name, ~version) {
        | Error(why) => Error(why)
        | Ok(true) =>
          Console.log(`  ${version}, released here already`)
          Ok(None)
        | Ok(false) =>
          Console.log(`  ${version}, which no release here lists`)
          let tag = `v${version}`
          switch await commitOf(upstream, tag) {
          | Error(why) => Error(why)
          | Ok(commit) =>
            Console.log(`  upstream's ${tag} is ${commit}`)
            (await hashes(runtime, pin, version))
            ->Result.flatMap(hashes =>
              build(runtime, pin, version, hashes, {repository: upstream, tag, commit})
            )
            ->Result.map(built => Some(built))
          }
        }
      }
    }
  }
}

/** What was built released under the UTC day, a new release drafted whole and published last, or
 * the day's published one added to, its manifest merged and uploaded after archives and rows. */
let release = async (builds, ~releases) => {
  let tag = Image.day(Date.now())
  let named = releases->Array.filter(release => release->Image.text("tag_name") == Some(tag))
  let published =
    named->Array.find(release => release->Image.field("draft") != Some(JSON.Encode.bool(true)))
  let gh = args => run("gh", [...args, "--repo", repository])
  let manifest = `${root}/dist/${Image.manifestFile}`
  let write = existing => {
    if !dry {
      Host.mkdirSync(`${root}/dist`, {recursive: true})
      Host.writeFileSync(
        manifest,
        Image.merged(existing, ~release=tag, builds->Array.map(({entry}) => entry)),
      )
    }
  }
  let rows = notes => builds->Array.reduce(notes, (notes, {row}) => Image.appended(notes, row))
  switch published {
  | Some(release) =>
    Console.log(`release ${tag}, added to`)
    switch await manifestOf(release) {
    | Error(why) => Error(why)
    | Ok(existing) =>
      write(existing)
      builds
      ->Array.reduce(Ok(), (done, {archives}) =>
        done->Result.flatMap(() => gh(["release", "upload", tag, ...archives, "--clobber"]))
      )
      ->Result.flatMap(() =>
        gh(["release", "edit", tag, "--notes", rows(release->Image.text("body")->Option.getOr(""))])
      )
      ->Result.flatMap(() => gh(["release", "upload", tag, manifest, "--clobber"]))
    }
  | None =>
    Console.log(`release ${tag}, new`)
    write(None)
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
          rows(""),
          ...builds->Array.flatMap(({archives}) => archives),
          manifest,
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
      let released = builds == [] ? Ok() : await release(builds, ~releases)
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
