/*** The repository's GitHub description passed to Docker Hub through the step's output. */
@module("node:fs") external appendFileSync: (string, string) => unit = "appendFileSync"

let main = () => {
  let repository = Host.env->Dict.get("GITHUB_REPOSITORY")->Option.getOrThrow
  let output = Host.env->Dict.get("GITHUB_OUTPUT")->Option.getOrThrow
  switch Host.capture(
    "gh",
    ["api", `repos/${repository}`],
    {
      cwd: Host.cwd(),
      encoding: "utf8",
    },
  ) {
  | {status, stdout} if status->Nullable.toOption == Some(0) =>
    let description =
      stdout
      ->Nullable.toOption
      ->Option.getOrThrow
      ->JSON.parseOrThrow
      ->Image.text("description")
      ->Option.getOr("null")
    appendFileSync(output, `text=${description}\n`)
  | _ => Host.exit(1)
  }
}

main()
