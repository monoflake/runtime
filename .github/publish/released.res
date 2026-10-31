/** Release membership belongs to the workspace's scripts/release/release.res. */
type capturing = {cwd: string, encoding: string, maxBuffer: int}
@module("node:child_process")
external capture: (string, array<string>, capturing) => Host.captured = "spawnSync"

let call = (~root, script, args) =>
  switch Host.env->Dict.get("WORKSPACE") {
  | None => Error("no WORKSPACE, which mise sets from the workspace's mise.toml")
  | Some(workspace) =>
    Ok(
      capture(
        "node",
        [`${workspace}/scripts/${script}.res.mjs`, ...args],
        {cwd: root, encoding: "utf8", maxBuffer: 67108864},
      ),
    )
  }

let holds = (~root, ~name, ~version) =>
  call(~root, "release/release", ["holds", name, version])->Result.flatMap(result =>
    switch result.status->Nullable.toOption {
    | Some(0) => Ok(true)
    | Some(2) => Ok(false)
    | _ => Error("workspace release holds failed")
    }
  )

let fetched = (~root, command, value) =>
  call(~root, "bindings/github", [command, value])->Result.flatMap(result =>
    result.status->Nullable.toOption == Some(0)
      ? Ok(result.stdout->Nullable.toOption->Option.getOr(""))
      : Error("workspace GitHub fetch failed")
  )

/** The workspace owns the listing consumed by scripts/pins.res. */
let listed = (~root) =>
  call(~root, "release/release", ["listed"])->Result.flatMap(result =>
    if result.status->Nullable.toOption != Some(0) {
      Error("workspace release listed failed")
    } else {
      try {
        switch JSON.parseOrThrow(
          result.stdout->Nullable.toOption->Option.getOr(""),
        )->JSON.Decode.array {
        | Some(entries) => Ok(entries)
        | None => Error("workspace release listed printed no list")
        }
      } catch {
      | JsExn(_) => Error("workspace release listed printed no JSON")
      }
    }
  )
