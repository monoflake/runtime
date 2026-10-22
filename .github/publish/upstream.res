/***
 * What a runtime's upstream published, and the version a run takes past the release delay
 * `pnpm-workspace.yaml` sets.
 */

/** A version upstream published, and when, in milliseconds since the epoch. */
type published = {version: string, at: float}

let field = (json, name) => json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(name))
let text = (json, name) => json->field(name)->Option.flatMap(JSON.Decode.string)
let time = stamp => Date.fromString(stamp)->Date.getTime

let parsed = (document, ~what) =>
  try Ok(JSON.parseOrThrow(document)) catch {
  | JsExn(_) => Error(`${what} is not JSON`)
  }

/** The delay in minutes that `minimumReleaseAge` gives, in `pnpm-workspace.yaml`'s text. */
let delay = text =>
  switch /^minimumReleaseAge:\s*(\d+)\s*$/m
  ->RegExp.exec(text)
  ->Option.map(RegExp.Result.matches) {
  | Some([Some(minutes)]) =>
    minutes->Int.fromString->Option.mapOr(Error("minimumReleaseAge is not a number"), m => Ok(m))
  | _ => Error("no minimumReleaseAge")
  }

/** A package's document in the npm registry, its `latest` tag and each version with its time. */
let npm = document =>
  parsed(document, ~what="the registry's document")->Result.flatMap(document => {
    let latest = document->field("dist-tags")->Option.flatMap(tags => tags->text("latest"))
    let versions = document->field("versions")->Option.flatMap(JSON.Decode.object)
    let times = document->field("time")
    switch (latest, versions, times) {
    | (None, _, _) => Error("the registry's document has no latest tag")
    | (_, None, _) => Error("the registry's document has no versions")
    | (_, _, None) => Error("the registry's document has no publish times")
    | (Some(latest), Some(versions), Some(times)) =>
      // `time` keeps a version since unpublished, which `versions` does not.
      let published =
        versions
        ->Dict.keysToArray
        ->Array.filterMap(version =>
          times->text(version)->Option.map(stamp => {version, at: time(stamp)})
        )
        ->Array.filter(({at}) => !Float.isNaN(at))
      Ok((latest, published))
    }
  })

/** A page of GitHub's releases of a repository, each one published and not a prerelease. */
let github = document =>
  parsed(document, ~what="the releases' document")->Result.flatMap(document =>
    switch document->JSON.Decode.array {
    | None => Error("the releases' document is not a list")
    | Some(releases) =>
      Ok(
        releases->Array.filterMap(release => {
          let flag = name => release->field(name)->Option.flatMap(JSON.Decode.bool)
          switch (release->text("tag_name"), release->text("published_at")) {
          | (Some(tag), Some(stamp))
            if flag("draft") == Some(false) && flag("prerelease") == Some(false) =>
            Some({
              version: tag->String.startsWith("v") ? tag->String.slice(~start=1) : tag,
              at: time(stamp),
            })
          | _ => None
          }
        }),
      )
    }
  )

/** The versions every list holds, each at the latest of its times, so all of them are past it. */
let everywhere = lists =>
  switch lists {
  | [] => []
  | _ =>
    lists
    ->Array.getUnsafe(0)
    ->Array.filterMap(({version}) =>
      lists
      ->Array.map(list => list->Array.find(p => p.version == version)->Option.map(p => p.at))
      ->Array.reduce(Some(Float.Constants.negativeInfinity), (latest, at) =>
        switch (latest, at) {
        | (Some(latest), Some(at)) => Some(Math.max(latest, at))
        | _ => None
        }
      )
      ->Option.map(at => {version, at})
    )
  }

/** A release's numbers, or none for a prerelease or anything else not plain dotted numbers. */
let numbers = version =>
  switch version
  ->String.split(".")
  ->Array.map(part => /^\d+$/->RegExp.test(part) ? Int.fromString(part) : None) {
  | parts if parts->Array.every(Option.isSome) => Some(parts->Array.filterMap(x => x))
  | _ => None
  }

let compare = (a, b) => {
  let rec at = index =>
    switch (a[index], b[index]) {
    | (None, None) => 0
    | (None, Some(_)) => -1
    | (Some(_), None) => 1
    | (Some(x), Some(y)) => x == y ? at(index + 1) : x < y ? -1 : 1
    }
  at(0)
}

/** What a run takes, the highest release past the delay and no higher than `bound`, and the
 * higher ones held back. */
type chosen = {take: option<string>, held: array<string>}

// The highest release, not the latest published, since wasmtime publishes patches to older majors.
let choose = (published, ~bound=?, ~delay, ~now) => {
  let ceiling = bound->Option.flatMap(numbers)
  let ready = now -. Int.toFloat(delay) *. 60_000.
  let candidates =
    published
    ->Array.filterMap(p => numbers(p.version)->Option.map(n => (n, p)))
    ->Array.filter(((n, _)) => ceiling->Option.mapOr(true, c => compare(n, c) <= 0))
    ->Array.toSorted(((a, _), (b, _)) => Int.toFloat(compare(b, a)))
  let take = candidates->Array.findIndex(((_, p)) => p.at <= ready)
  {
    take: take < 0 ? None : candidates[take]->Option.map(((_, p)) => p.version),
    held: candidates
    ->Array.slice(~start=0, ~end=take < 0 ? candidates->Array.length : take)
    ->Array.map(((_, p)) => p.version),
  }
}
