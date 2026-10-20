# Onec Docker

English | [Русский](README_ru.md)

The 1C:Enterprise 8.3 platform in Docker. A server in a container suits development and test
environments: it is easy to start, to recreate from scratch or to move to another platform
version. The `full` image runs the same server with the platform clients and a virtual display.

The stack has no DBMS, so server infobases need a separate PostgreSQL or Microsoft SQL Server.

> [!WARNING]
> The server is not meant to be reachable from the internet. The cluster has no administrators,
> and Docker publishes its ports on all network interfaces of the host.

## Requirements

- The 1C:Enterprise 8.3 platform distribution for Linux x86_64. The project is tested with
  8.3.25.1633.
- Docker Engine with BuildKit, or Docker Desktop.
- Docker Compose 2.24.4 or newer.
- At least 8 GB of free disk space to build the images, 16 GB with `full`.

## Images

| Image | Contents |
|---|---|
| `onec-devops/1cv8-server` | The 1C:Enterprise server with the administration server and the `rac`, `ibcmd` and `ibsrv` utilities. It has no clients. |
| `onec-devops/1cv8-full` | The same server with the clients, a virtual display and a VNC server to watch the display from the host, also in a browser. It runs the clients in the container itself, for example for automated tests. Only the thin client is installed by default, the thick one can be added. |

## Getting started

1. Download the platform distribution for Linux from https://releases.1c.ru, the archive
   `server64_<version>.zip` or `.tar.gz`, and put it into `distr/` without unpacking. The
   build takes the archive by the version, so the directory may hold archives of several
   versions.

2. Copy `.env.example` to `.env` and set `ONEC_VERSION` in it to the platform version, for
   example `8.3.25.1633`:

   ```sh
   cp .env.example .env
   ```

3. Build the image, `server` or `full`:

   ```sh
   docker compose build server
   ```

   The result is the image `onec-devops/1cv8-server:8.3.25.1633`, tagged with the platform
   version.

4. Start the server:

   ```sh
   docker compose up -d
   ```

5. Check that the cluster is up:

   ```sh
   docker compose exec server rac cluster list
   ```

> [!WARNING]
> The image contains the 1C:Enterprise platform. The license of this project gives no right to
> distribute it, so do not push the image to a public registry.

## Configuration

The build and the containers are configured in `.env`, and [.env.example](.env.example) lists all
the variables. Only `ONEC_VERSION` is required, compose commands do not run without it.

| Variable | Default | Description |
|---|---|---|
| `ONEC_VERSION` | | The platform version. The build takes the archive of this version from `distr/`. |
| `COMPOSE_PROFILES` | | The service for compose commands without a service name, `server` or `full`, see [Running the server](#running-the-server). |
| `IMAGE_NAMESPACE` | `onec-devops` | The prefix of the image names `onec-devops/1cv8-server` and `onec-devops/1cv8-full`. |
| `NOVNC_PORT` | `6080` | The host port of the noVNC page of the `full` image, see [Running clients](#running-clients). |
| `ONEC_CLIENT_COMPONENTS` | `client_thin` | Components installed only into the `full` image, separated by commas, see [Platform components](#platform-components). |
| `ONEC_COMPONENTS` | `server,ws` | Components installed into both images, separated by commas, see [Platform components](#platform-components). |
| `ONEC_DEBUG` | `false` | Turns debugging on, see [Debugging](#debugging). |
| `ONEC_DEBUG_PORT` | `1550` | The port of the debug server. |
| `ONEC_HOSTNAME` | `onec-server` | The name clients connect to the server by, see [Connecting to the server](#connecting-to-the-server). |
| `ONEC_ARCHIVE` | `server64_<version>.zip` or `.tar.gz` | The name of the platform archive in `distr/`, if it differs from the one on releases.1c.ru. |
| `ONEC_MAC_ADDRESS` | `02:1c:08:03:00:01` | The MAC address of the server. Software licenses are bound to it. |
| `ONEC_PORT` | `1540` | The port of the server agent. |
| `ONEC_RANGE_START` / `ONEC_RANGE_END` | `1560` / `1591` | The port range of the worker processes. |
| `ONEC_RAS_PORT` | `1545` | The port of the administration server. |
| `ONEC_REGPORT` | `1541` | The port of the cluster manager. |
| `SCREEN_WIDTH` / `SCREEN_HEIGHT` | `1920` / `1080` | The width and the height of the virtual display of the `full` image in pixels. |
| `SCREEN_DEPTH` | `24` | The color depth of the virtual display in bits. |
| `SCREEN_DPI` | `96` | The resolution of the virtual display. The size of the fonts depends on it. |
| `START_DISPLAY` | `true` | Whether the `full` image starts the virtual display, see [Running clients](#running-clients). |
| `TZ` | `Europe/Moscow` | The time zone of the containers. The time `ТекущаяДата()` returns on the server depends on it. |
| `VNC_PASSWORD` | | The password of the VNC server of the `full` image, at most 8 characters. noVNC asks for it too. There is no password by default, see [Running clients](#running-clients). |
| `VNC_PORT` | `5900` | The host port of the VNC server of the `full` image, see [Running clients](#running-clients). |

### Platform components

The platform installer consists of components, listed in the administrator guide, in the section
[«Пакетная установка»](https://its.1c.ru/db/v8325doc#bookmark:adm:TI000001075). Server
components are listed in `ONEC_COMPONENTS`, client ones in `ONEC_CLIENT_COMPONENTS`.

Both images get `server` and `ws` by default. The `server` component brings the server cluster,
the administration server `ras` and the `rac`, `ibcmd` and `ibsrv` utilities, so the separate
`server_admin` component is not needed. The `ws` component adds the engine of file infobases,
without which `ibcmd` and `ibsrv` do not work with them.

The `full` image also gets `client_thin`, the thin client, which does not open file infobases
directly. The thick client and Designer are left out to keep the image smaller. They are
installed with `ONEC_CLIENT_COMPONENTS=client_thin,client_full` in `.env` and a rebuild of the
image.

### Changing ports

If the standard ports are taken on the host, for example by an installed 1C server or another
copy of the project, other ones are set in `.env`. These values shift all the ports by 1000:

```sh
ONEC_PORT=2540
ONEC_REGPORT=2541
ONEC_RANGE_START=2560
ONEC_RANGE_END=2591
ONEC_RAS_PORT=2545
ONEC_DEBUG_PORT=2550
VNC_PORT=6900
NOVNC_PORT=7080
```

### Debugging

`ONEC_DEBUG=true` in `.env` turns debugging on. The server then starts with `-debug -http`, and
the debug server `dbgs` listens on the port from `ONEC_DEBUG_PORT`, 1550 by default. It is
reached at `http://onec-server:1550`, and the server name must resolve the same way as when
[connecting clients](#connecting-to-the-server).

### Platform settings files

The server reads the settings files of the platform, such as `conf.cfg` and `logcfg.xml`, from
`/home/usr1cv8/.1cv8/1C/1cv8/conf`. The directory is inside the `srv-data` volume, so the
settings are easier to keep in a host directory mounted in its place with
`compose.override.yaml`. An example for the `server` service:

```yaml
services:
  server:
    volumes:
      - ./conf:/home/usr1cv8/.1cv8/1C/1cv8/conf:ro
```

The image has the directory `/var/log/1C` for the technological log, it is kept in the `logs`
volume.

The files are described in the administrator guide, in the appendix
[«Описание и расположение служебных файлов»](https://its.1c.ru/db/v8325doc/bookmark/adm/TI000000365).

## Running the server

`docker compose up -d` starts the service from `COMPOSE_PROFILES` in `.env`, which is `server` in
`.env.example`. With `COMPOSE_PROFILES=full` the `full` service runs instead. The services do not
run at the same time, because they take the same ports. So the server is stopped with
`docker compose down` before the value is changed, after the change the command no longer sees
it.

The container runs the 1C server and the administration server `ras`, through which `rac`
manages the cluster. If either of them exits, the container restarts. For the `full` image, `full`
takes the place of `server` in this and the following commands.

If Docker reports on start that a port is already taken, the server needs other ports, see
[Changing ports](#changing-ports).

The cluster data is kept in the `srv-data` volume, software licenses in the `licenses` volume and
the technological log in the `logs` volume.

### Connecting to the server

Clients connect to the server by the name from `ONEC_HOSTNAME`, `onec-server` by default. On the
client computer the name must point to the Docker host, for example with the line
`<IP of the Docker host> onec-server` in the `hosts` file. If the port of the cluster manager is
changed, it follows the name: `onec-server:<ONEC_REGPORT>`. The name is better left unchanged
after the first start, because the cluster is registered under it.

If the client runs on the same Windows machine as Docker Desktop, `hosts` points the name to the
IP of the WSL virtual machine rather than of the machine itself. The command
`wsl -d docker-desktop ip -4 addr show eth0` prints it, and it may change after a restart of
Windows or WSL.

### Standalone server

Instead of the cluster the container can run the standalone server `ibsrv`. It needs no server
license and no DBMS, serves one file infobase and publishes it over HTTP. For that the command
and the ports are changed in `compose.override.yaml`:

```yaml
services:
  server:
    command: ibsrv
    ports: !override
      - "8314:8314"
```

The container turns `healthy` when the server is ready to accept requests. It opens the port a
few seconds earlier, so it is better to wait for the state of the container than for the port.

On the first start the container creates an empty file infobase in the `srv-data` volume. On
later starts the infobase is already there and is left as it is. It opens in the thin client and
in a browser at `http://localhost:8314`.

Instead of an empty infobase the container can take a ready one. For that the infobase file
`1Cv8.1CD` or a `.dt` dump is mounted into the container, and the path to it inside the
container is set in `ONEC_INFOBASE_SOURCE`:

```yaml
services:
  server:
    command: ibsrv
    environment:
      ONEC_INFOBASE_SOURCE: /seed/1Cv8.1CD
    volumes:
      - ./base:/seed:ro
```

A `.1CD` file is copied into the `srv-data` volume, a `.dt` dump is restored into a new
infobase. The format is told by the contents of the file, so its name in the container may be
anything. The source file is not changed, but the infobase in it must be closed while it is
copied. The variable takes effect only on the first start. Once the volume has an infobase, the
file is not read and does not have to be mounted.

`ibsrv` keys follow the command, for example `command: ibsrv --name=demo --http-port=9000`. With
`ONEC_DEBUG=true` debugging over HTTP is turned on at the port from `ONEC_DEBUG_PORT`, which has
to be published too.

If the keys set their own location of the data or the infobase, such as `--data`, `--db-path` or
`--config`, the container creates no infobase and ignores `ONEC_INFOBASE_SOURCE`, and the
infobase has to be created beforehand with `ibcmd`. With a settings file of its own from
`--config` the server takes the address it listens on from that file.

Lasting settings of the standalone server are easier to keep in `ibsrv.yml` next to the other
[platform settings files](#platform-settings-files). If the file is there, the server starts with
it instead of the file of the image:

```yaml
server:
  address: any
  port: 9000
infobase:
  name: demo
```

Without the line `address: any` the server listens only on `localhost`, and the published port
does not answer. `ibcmd server config init` prints a template with all the parameters.

For the `full` service the list of ports also keeps the display ports `127.0.0.1:5900:5900` and
`127.0.0.1:6080:6080`.

### Running commands in the container

By default the container runs the server `ragent` together with `ras`. The `ras` command runs
only the administration server, the `ibsrv` command runs the [standalone server](#standalone-server),
and any other command runs as is. Additional server keys follow `ragent`, for example
`ragent -pingTimeout 30000`. The word `ragent` itself can be left out: if the command starts with
a key, the server is started. The container sets the keys `-port`, `-regport`, `-range`, `-d` and
`-seclev` itself and refuses them in the command. The ports are changed with the variables from
[Changing ports](#changing-ports). The platform utilities, such as `rac` and `ibcmd`, are called
by name.

A shell in the running server is opened with:

```sh
docker compose exec server bash
```

A separate container from the same image, not connected to the running server, is started like
this:

```sh
docker run --rm -it onec-devops/1cv8-server:8.3.25.1633 bash
```

`docker compose run server` does not suit this, because it creates a second container with the
same host name and MAC address in the network of the running server.

The image declares the server data directory `/home/usr1cv8/.1cv8` as a volume. The service in
`compose.yaml` keeps it in a named volume, as well as the licenses and the technological log. If
the server is started with `docker run`, the data volume needs a name too, for example
`-v onec-data:/home/usr1cv8/.1cv8`. Otherwise Docker creates an anonymous volume, and the next
container does not pick it up. `/var/1C/licenses` and `/var/log/1C` are not declared as volumes,
and without `-v` their contents go away with the container.

### Running as another user

The container runs as the user `usr1cv8` with UID and GID 999. If a command writes to a host
directory, for example saves a configuration file there, the container can run as your own user
with `--user`. The files on the host then belong to that user:

```sh
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" onec-devops/1cv8-server:8.3.25.1633 \
    ibcmd infobase create --db-path=/work/ib
```

The server with volumes runs without `--user`. The data in the volumes belongs to the user 999,
and another user cannot change it.

## Running clients

The clients run in a running `full` container, for example after `docker compose exec full bash`.
The container has no screen, so it starts the virtual display Xvfb next to the server, and the
clients open on it. `SCREEN_WIDTH` and `SCREEN_HEIGHT` set its resolution.

The display is shown in a browser at `http://localhost:6080` by the web client
[noVNC](https://novnc.com). `NOVNC_PORT` sets its host port. A regular VNC client connects to the
port from `VNC_PORT`, 5900 by default.

`VNC_PASSWORD` sets a password, which both the VNC client and noVNC then ask for. It can also be
passed as a file, such as a Docker secret. The path to the file in the container is set in
`VNC_PASSWORD_FILE`, which takes precedence over `VNC_PASSWORD`. An example for
`compose.override.yaml`:

```yaml
services:
  full:
    environment:
      VNC_PASSWORD_FILE: /run/secrets/vnc_password
    secrets:
      - vnc_password

secrets:
  vnc_password:
    file: ./vnc_password.txt
```

On the host the display ports are open only to the machine itself. Other containers in the same
Docker network reach the display directly, so a shared network calls for a password.

The display is shared by all the clients in the container. If a client needs a separate clean
display, for example in an automated run, the command runs through `xvfb-run -a`. Such a display
lives while the command runs and is not shown in the browser.

If the shared display is not needed, `START_DISPLAY=false` in `.env` turns it off. The container
then starts no Xvfb, Fluxbox, VNC server and noVNC, and the clients are left with `xvfb-run -a`.

By default the thin client does not open file infobases directly. A file infobase is created with
`ibcmd` and published with `ibsrv`, and the client connects to it over HTTP with the `/WS` key.
The container does this itself when it runs as a [standalone server](#standalone-server), and the
client is then started with `1cv8c ENTERPRISE /WS http://localhost:8314`.

## Changing the platform version

1. Put the archive of the new version into `distr/`.
2. Set the new version in `ONEC_VERSION` in `.env`.
3. Rebuild the image and restart the server:

   ```sh
   docker compose build server
   docker compose up -d
   ```

The volumes stay: the cluster data, the licenses and the technological log are kept. The image of
the old version stays too until it is removed.

## Platform licenses

Without a license, `ibcmd` creates infobases and loads and dumps configurations, and the thin
client works with an infobase published by `ibsrv` as long as no more than three client sessions
run at once. The thick client and Designer need a license.

Only software licenses work in the container, hardware protection keys are not supported. A
software license is bound to the parameters of the computer, the host name and the MAC address
among them. Compose sets them explicitly, so that they do not change when the container is
recreated. The other parameters, such as the processor and the memory, the container gets from
the Docker host. The license files are kept in the `licenses` volume.

## Contributing

Pull requests are welcome: bug fixes, new features, documentation improvements. A larger change
is better discussed in an issue first. [CONTRIBUTING.md](CONTRIBUTING.md) explains how the images
are built and tested.

## License

The code in this repository is distributed under the [Apache License 2.0](LICENSE). It does not
cover the 1C:Enterprise platform installed into the images.

The build accepts the license agreement of the Microsoft Core Fonts automatically.
