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
| `.github/workflows/` | Lints, builds and tests the images in GitHub Actions. |

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

The `Dockerfile` is checked with hadolint and the scripts with ShellCheck, of the same versions as
in CI:

```sh
docker run --rm -v "$PWD:/work" -w /work hadolint/hadolint:v2.15.1 /bin/hadolint Dockerfile
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:v0.11.0 docker/*.sh tests/*.sh
```

## CI

The [CI](.github/workflows/ci.yml) workflow runs the linters, builds both images and runs
`tests/smoke.sh` on them. It runs on pushes to `main` and on pull requests that change more than
`.md` files, and weekly to catch changes of the base image and the Debian packages.

Except for pull requests, the tested images are pushed to the GitHub Container registry as the
private packages `1cv8-server` and `1cv8-full` of the repository owner, tagged with the platform
version, for example `ghcr.io/onec-devops/1cv8-server:8.3.25.1633`. Other repositories, such as
the CI of a project that tests against the platform, get read access to them under
"Manage Actions access" in the package settings. The packages must stay private, because the
images contain the platform, and a package made public cannot be made private again.

The workflow downloads the platform installer from the GitHub Container registry, where it is
kept as the private package `1cv8-installer` of the repository owner, tagged with the platform
version. The installer is uploaded from `distr/` with [ORAS](https://oras.land):

```sh
cd distr
oras login ghcr.io -u <GitHub user name>
oras push --artifact-type application/vnd.onec-devops.1cv8.installer \
    ghcr.io/<repository owner>/1cv8-installer:8.3.25.1633 setup-full-8.3.25.1633-x86_64.run
```

The login needs a classic personal access token with the `write:packages` scope. A new package is
private. To let the workflow download it, add the repository with the `Read` role under
"Manage Actions access" in the package settings. A fork is set up the same way to run the
workflow.

The platform versions under test are listed in `matrix.onec-version` of the workflow, and each of
them needs its installer in the registry.

## License

By contributing, you agree that your contribution is licensed under the
[Apache License 2.0](LICENSE). Source files carry no license header; the `LICENSE` file covers
the whole repository.
