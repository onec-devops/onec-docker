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
| `docker/install-1cv8.sh` | Installs the platform from its archive in `distr/` unattended. |
| `docker/install-1cedt.sh` | Installs 1C:EDT from its archive in `distr/` unattended, keeping the support of only the platform versions in `EDT_PLATFORM_VERSIONS`. |
| `docker/entrypoint.sh` | Starts `ragent` with `ras` or the standalone server `ibsrv` with the parameters from the environment variables, and in the `full` image also the virtual display. |
| `docker/healthcheck.sh` | Checks whether the server running in the container is ready. |
| `docker/ibsrv.yml` | The default settings of the standalone server, with which it listens on all addresses, not only on `localhost`. |
| `compose.yaml` | Builds and runs the images. |
| `tests/` | Tests of the built images. |
| `.github/workflows/` | Lints, builds and tests the images in GitHub Actions. |

The archives are bind-mounted into the build rather than copied, so they do not end up in a
layer. The platform and 1C:EDT are installed in separate stages and copied into the images,
which share everything else in the `runtime` stage. The `server-edt` and `full-edt` images are the
`server` and `full` images with 1C:EDT added.

## Building and testing

You need bash for the tests, Git Bash works on Windows. Build the images as described in
[Getting started](README.md#getting-started) and [1C:EDT](README.md#1cedt), then run:

```sh
tests/smoke.sh
```

The script tests the images of the `server`, `full`, `server-edt` and `full-edt` services that
are built and skips the others. It takes the versions and the image prefix from `.env` or the
environment and prints the results in the [TAP](https://testanything.org) format. The server images get the
checks of the server, the full images those of the clients, and the 1C:EDT images those of
1C:EDT as well. The checks are listed at the top of the [script](tests/smoke.sh).

To test only some images, name their services. A named image that is not built stops the run,
which is how CI calls the script:

```sh
tests/smoke.sh server-edt full-edt
```

The tests can run next to a working server. The test containers publish no ports, and the
services run under the separate compose project `onec-test`. The first run pulls
`curlimages/curl` for the OData requests. The test containers and volumes are removed after the
run.

The `Dockerfile` is checked with hadolint and the scripts with ShellCheck, of the same versions as
in CI:

```sh
docker run --rm -v "$PWD:/work" -w /work hadolint/hadolint:v2.15.1 /bin/hadolint Dockerfile
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:v0.11.0 docker/*.sh tests/*.sh
```

## CI

The [CI](.github/workflows/ci.yml) workflow runs the linters, builds the images and runs
`tests/smoke.sh` on them. It runs on pushes to `main` and on pull requests that change more than
`.md` files, and weekly to catch changes of the base image and the Debian packages.

On `main`, the tested images are pushed to the GitHub Container registry as the
private packages `1cv8-server` and `1cv8-full` of the repository owner, for example
`ghcr.io/onec-devops/1cv8-server:8.3.27.2342` and
`ghcr.io/onec-devops/1cv8-server:8.3.27.2342-edt-2026.1.3`. Other repositories, such as the CI of
a project that tests against the platform, get read access to them under
"Manage Actions access" in the package settings. The packages must stay private, because the
images contain the platform, and a package made public cannot be made private again.

The workflow downloads the platform archive from the GitHub Container registry, where it is
kept as the private package `1cv8-installer` of the repository owner, tagged with the platform
version. The archive is uploaded from `distr/` with [ORAS](https://oras.land):

```sh
cd distr
oras login ghcr.io -u <GitHub user name>
oras push --artifact-type application/vnd.onec-devops.1cv8.installer \
    ghcr.io/<repository owner>/1cv8-installer:8.3.27.2342 server64_8_3_27_2342.zip
```

The login needs a classic personal access token with the `write:packages` scope. A new package is
private. To let the workflow download it, add the repository with the `Read` role under
"Manage Actions access" in the package settings. A fork is set up the same way to run the
workflow.

The platform versions under test are listed in `matrix.onec-version` of the workflow, and each
of them needs its archive in the registry. Each version is built twice: as the `server` and
`full` images, and as the `server-edt` and `full-edt` images with the 1C:EDT version from
`matrix.include`. The 1C:EDT archive is kept the same way as the private package
`1cedt-installer`, tagged with the 1C:EDT version:

```sh
cd distr
oras push --artifact-type application/vnd.onec-devops.1cedt.installer \
    ghcr.io/<repository owner>/1cedt-installer:2026.1.3 \
    1c_edt_distr_offline_2026.1.3_25_linux_x86_64.tar.gz
```

## License

By contributing, you agree that your contribution is licensed under the
[Apache License 2.0](LICENSE). Source files carry no license header; the `LICENSE` file covers
the whole repository.
