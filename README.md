# Runtime

**workerd** and **wasmtime**, built as [OCI images](https://github.com/opencontainers/image-spec/blob/main/manifest.md).

## Docker & Compose

```sh
docker compose up
#OR
docker pull canmi/workerd
docker pull canmi/wasmtime
```

Compose serves `worker/config.capnp` on **25683** and `component/app.wasm` on **24947**.

## Containerd

```sh
ctr images pull docker.io/canmi/wasmtime:latest
ctr run --rm docker.io/canmi/wasmtime:latest wasmtime wasmtime --version
ctr images import wasmtime-<version>-linux-x86_64.tar
```

Each release here also holds every image as an OCI archive, one per architecture, for a machine
that takes it with `ctr images import` rather than from a registry.

## Podman

```sh
podman run --rm docker.io/canmi/wasmtime --version
```

## License

MIT License © 2026 [Canmi](https://canmi.net)
