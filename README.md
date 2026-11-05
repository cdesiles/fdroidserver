# fdroidserver

[![image](https://github.com/cdesiles/fdroidserver/actions/workflows/image.yml/badge.svg)](https://github.com/cdesiles/fdroidserver/actions/workflows/image.yml)

A small container image to host your own [F-Droid](https://f-droid.org/) repository of ready-made APKs: [fdroidserver](https://gitlab.com/fdroid/fdroidserver) keeps the signed index up to date, busybox httpd serves it.

```sh
docker pull ghcr.io/cdesiles/fdroidserver
```

About 360 MB, for `linux/amd64` and `linux/arm64`. Built on Debian's own fdroidserver package, an image takes 1.4 GB: androguard pulls in matplotlib, scipy and IPython, apksigner a desktop Java with GTK and Mesa. This one has:

- fdroidserver from PyPI, with every dependency pinned in [requirements.txt](requirements.txt);
- Debian's apksigner, and a Java runtime cut down by jlink to what keytool, jarsigner and apksigner need;
- busybox httpd.

It publishes APKs you already have: it doesn't build apps from source.

## Quick start

1. Create the repository in `data/`, with its signing key and `config.yml`:

    ```sh
    docker run --rm -v "$PWD/data:/fdroid" ghcr.io/cdesiles/fdroidserver fdroid init --no-prompt
    ```

    In `data/config.yml`, set `repo_url` (e.g. `https://apk.example.org/repo`), `repo_name` and `repo_description`. Back up `config.yml` and `keystore.p12`: phones trust that key, and if it's lost every phone must add the repository again.

2. Put your APKs in `data/repo/` and start the server:

    ```yaml
    # compose.yaml
    services:
      fdroid:
        image: ghcr.io/cdesiles/fdroidserver:latest
        ports:
          - "8080:80"
        volumes:
          - ./data:/fdroid
          - ./data/repo:/var/www/html/repo:ro
    ```

    ```sh
    docker compose up -d
    ```

3. In the F-Droid app, add the repository by its `repo_url`. Beyond your LAN, put a reverse proxy with HTTPS in front.

## How it runs

The default command, [fdroid-serve](fdroid-serve):

- runs `fdroid update -c` at start, then every `FDROID_UPDATE_INTERVAL` (default `24h`): new APKs get their metadata and the index is signed again. A failed first update stops the container; a later one leaves the previous index served.
- serves `/var/www/html` on port 80. Mount `repo/` read-only on `/var/www/html/repo`, as above: `config.yml` and the keystore, next to it in `/fdroid`, then stay out of reach.

To index new APKs right away: `docker compose exec fdroid fdroid update -c`. Any other `fdroid` command runs the same way.

| | |
|---|---|
| `/fdroid` | The repository: `config.yml`, `keystore.p12`, `repo/`, `metadata/`. Keep it |
| `/var/www/html/repo` | `repo/` again, read-only: what httpd serves |
| Port | 80 |
| User | root. With rootless Podman, that's your own user; with Docker, files it creates in `data/` belong to root |

## Tags

On every commit to `main`, GitHub Actions builds the image, checks it on a throwaway repository (signing key, a real APK indexed, signatures, HTTP) and publishes:

- `<fdroidserver version>-<build>`, e.g. `2.4.5-1`: one per build, to pin;
- `<fdroidserver version>` and `latest`: the newest build.

Dependabot proposes updates of the base image, the Python pins and the actions, and each of its pull requests goes through the same build and check.

## Building

```sh
make image                        # fdroidserver:<version>, for this machine
make check                        # build, then the same check as CI
make check PLATFORM=linux/amd64   # for an x86_64 server, from an arm64 laptop (emulated)
make lock                         # pin the latest fdroidserver and its dependencies
```

`CONTAINER=podman` uses podman instead of docker. The pins only move with a passing check: a new androguard has broken fdroidserver before (4.1.4 with fdroidserver 2.4.2).

## License

[GPL-2.0](LICENSE)
