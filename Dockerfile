# fdroidserver for a repository of ready-made APKs: `fdroid update` keeps the
# signed index fresh, busybox httpd serves it.
#
# Debian's fdroidserver package takes ~1.4 GB: androguard depends on
# matplotlib/scipy/ipython, apksigner on a desktop JRE (GTK, Mesa). Instead:
# fdroidserver from PyPI, pinned by requirements.txt; Debian's apksigner jars;
# a Java runtime cut down by jlink to what keytool, jarsigner and apksigner use.
FROM docker.io/library/debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2 AS build
WORKDIR /tmp/debs
RUN apt-get update \
 && apt-get install -y --no-install-recommends binutils openjdk-21-jdk-headless python3 python3-venv \
 && apt-get download apksigner libapksig-java \
 && for deb in ./*.deb; do dpkg-deb -x "$deb" /out; done
# keytool: java.base, jarsigner: jdk.jartool, EC-signed APKs: jdk.crypto.ec.
# --strip-debug runs objcopy, hence binutils.
RUN jlink --add-modules java.base,jdk.crypto.ec,jdk.jartool \
      --strip-debug --no-man-pages --no-header-files --output /opt/java
# Only pinned code runs: --no-deps and `pip check` make requirements.txt pin
# the whole tree, consistently; the packages published as source only build
# with the pinned requirements-build.txt instead of whatever PyPI has.
COPY requirements.txt requirements-build.txt /tmp/
RUN python3 -m venv /opt/fdroidserver \
 && cd /opt/fdroidserver/bin \
 && ./pip install --no-cache-dir --no-deps --requirement /tmp/requirements-build.txt \
 && ./pip install --no-cache-dir --no-compile --no-deps --no-build-isolation \
      --requirement /tmp/requirements.txt \
 && ./pip check \
 && ./pip uninstall --yes babel setuptools pip

FROM docker.io/library/debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
RUN apt-get update \
 && apt-get install -y --no-install-recommends busybox python3 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/java /opt/java
COPY --from=build /opt/fdroidserver /opt/fdroidserver
COPY --from=build /out/usr/bin/apksigner /usr/bin/apksigner
COPY --from=build /out/usr/share/java/ /usr/share/java/
# busybox httpd sends no Content-Type for these
RUN printf '%s\n' \
      .apk:application/vnd.android.package-archive \
      .jar:application/java-archive \
      .json:application/json > /etc/httpd.conf \
 && mkdir -p /var/www/html/repo
COPY --chmod=0755 fdroid-serve /usr/local/bin/fdroid-serve
# GitPython refuses to import without a git binary; `fdroid update` runs no git.
# No .pyc: -60 MB, and a daily `fdroid update` starts just as fast without.
ENV PATH=/opt/fdroidserver/bin:/opt/java/bin:$PATH \
    GIT_PYTHON_REFRESH=quiet \
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /fdroid
EXPOSE 80
CMD ["fdroid-serve"]
