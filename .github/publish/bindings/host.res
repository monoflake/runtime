/***
 * What the glue takes of node, its arguments, environment and exit, its files, the network, a
 * hash and a command run as a child.
 */
@module("node:process") external argv: array<string> = "argv"
@module("node:process") external env: dict<string> = "env"
@module("node:process") external exit: int => unit = "exit"
@module("node:process") external cwd: unit => string = "cwd"

@module("node:fs") external readFileSync: (string, @as("utf8") _) => string = "readFileSync"
@module("node:fs") external readBytes: string => Uint8Array.t = "readFileSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:fs") external readdir: string => array<string> = "readdirSync"
@module("node:fs") external existsSync: string => bool = "existsSync"
type made = {recursive: bool}
@module("node:fs") external mkdirSync: (string, made) => unit = "mkdirSync"

type response
type init = {headers: dict<string>}
@val external fetch: (string, init) => promise<response> = "fetch"
@get external ok: response => bool = "ok"
@get external status: response => int = "status"
@send external text: response => promise<string> = "text"
@send external arrayBuffer: response => promise<ArrayBuffer.t> = "arrayBuffer"

type hash
@module("node:crypto") external createHash: string => hash = "createHash"
@send external update: (hash, Uint8Array.t) => hash = "update"
@send external digest: (hash, string) => string = "digest"

type spawned = {status: Nullable.t<int>}
type options = {cwd: string, stdio: string, env?: dict<string>}
@module("node:child_process")
external spawnSync: (string, array<string>, options) => spawned = "spawnSync"
