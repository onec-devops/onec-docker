# Contributing

Pull requests are welcome: bug fixes, new features, documentation. For a larger change, open an
issue first to agree on the approach.

## Sending a change

- Base the branch on `main` and keep each commit to one change.
- Keep code comments and script messages in English.
- Cover a change of behaviour with a check in `tests/smoke.sh`. A check tests what the image
  does, not what the `Dockerfile` states.
- Make sure the linters and `tests/smoke.sh` pass.
- Update both [README.md](README.md) and [README_ru.md](README_ru.md).

## How the images work

| Path | Purpose |
|---|---|
| `Dockerfile` | Builds the images on Debian 12 (bookworm-slim). |
| `docker/install-1cv8.sh` | Installs the platform from `distr/` unattended. |
| `docker/entrypoint.sh` | Starts `ragent` with `ras` or the standalone server `ibsrv` with the parameters from the environment variables, and in the `full` image also the virtual display. |
| `docker/healthcheck.sh` | Checks whether the server running in the container is ready. |
| `docker/ibsrv.yml` | The default settings of the standalone server, with which it listens on all addresses, not only on `localhost`. |
| `compose.yaml` | Builds and runs both images. |
| `tests/` | Tests of the built images. |

The installer is bind-mounted into the build rather than copied, so it does not end up in a
layer. The platform is installed in separate stages and copied into the images, which share
everything else in the `runtime` stage.

## Building and testing

You need bash for the tests, Git Bash works on Windows. Build both images as described in
[Getting started](README.md#getting-started), then run:

```sh
tests/smoke.sh
```

The script takes the version and the image prefix from `.env` and prints the results in the
[TAP](https://testanything.org) format. Without the `server` image it does not start, and without
the `full` image its checks are skipped. The checks are listed at the top of the
[script](tests/smoke.sh).

The tests can run next to a working server. The test containers publish no ports, and the
services run under the separate compose project `onec-test`. The first run pulls
`curlimages/curl` for the OData requests. The test containers and volumes are removed after the
run.

The `Dockerfile` is checked with hadolint and the scripts with ShellCheck:

```sh
docker run --rm -v "$PWD:/work" -w /work hadolint/hadolint:v2.15.1 /bin/hadolint Dockerfile
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:v0.11.0 docker/*.sh tests/*.sh
```

## License

By contributing, you agree that your contribution is licensed under the
[Apache License 2.0](LICENSE). Source files carry no license header; the `LICENSE` file covers
the whole repository.
