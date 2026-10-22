/***
 * What every published release here lists, read by the workspace's scripts/release, which reads
 * each manifest in either of its shapes.
 */
/** Each artifact a published release's manifest lists, the newest release first. */
let listed = (~root) =>
  switch Host.env->Dict.get("WORKSPACE") {
  | None => Error("no WORKSPACE, which mise sets from the workspace's mise.toml")
  | Some(workspace) =>
    let script = `${workspace}/scripts/release/release.res.mjs`
    switch Host.capture("node", [script, "listed"], {cwd: root, encoding: "utf8"}) {
    | {status, stdout} if status->Nullable.toOption == Some(0) =>
      switch JSON.parseOrThrow(stdout->Nullable.toOption->Option.getOr(""))->JSON.Decode.array {
      | Some(entries) => Ok(entries)
      | None => Error(`${script} listed printed no list`)
      | exception JsExn(_) => Error(`${script} listed printed no JSON`)
      }
    | _ => Error(`${script} listed failed`)
    }
  }
