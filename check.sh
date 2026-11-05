#!/bin/sh
# Checks an image on a throwaway repository, the way it runs in production:
# the first key and index, then the default command indexing a real APK,
# signing the index and serving repo/ (and nothing else) over HTTP.
#
# Usage: check.sh IMAGE
#   CONTAINER=podman  to use podman instead of docker
#   PLATFORM=linux/amd64  to run an image built for another platform
set -eu

image=$1
container=${CONTAINER:-docker}
name=fdroidserver-check-$$
# F-Droid Privileged Extension 0.2.14: a real signed APK, 46 kB
apk=org.fdroid.fdroid.privileged_2140.apk
apk_sha256=6261445e671bea58fd8d5b7c10140845a44a01940cc2e1ad8c52e3aa4a264e94

fail() {
	echo "FAIL: $*" >&2
	exit 1
}
run() {
	if [ -n "${PLATFORM:-}" ]; then
		"$container" run --platform "$PLATFORM" "$@"
	else
		"$container" run "$@"
	fi
}
in_container() { "$container" exec "$name" "$@"; }
sha256() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d ' ' -f 1; }

mkdir -p .cache
[ -f ".cache/$apk" ] || curl -fsSL -o ".cache/$apk" "https://f-droid.org/repo/$apk"
[ "$(sha256 ".cache/$apk")" = "$apk_sha256" ] || fail ".cache/$apk: unexpected SHA-256"

work=$(mktemp -d "${TMPDIR:-/tmp}/fdroidserver-check.XXXXXX")
# The container writes as root: on Linux, the leftovers may not be ours to delete
trap '"$container" rm -f "$name" >/dev/null 2>&1; rm -rf "$work" 2>/dev/null || true' EXIT
mkdir -p "$work/repo" "$work/metadata"
cat >"$work/config.yml" <<'EOF'
repo_url: https://apk.example.org/repo
repo_name: Check
repo_description: fdroidserver image check
repo_keyalias: fdroid-repo-key
keystore: keystore.p12
keystorepass: check-keystore-password
keypass: check-keystore-password
keydname: CN=apk.example.org
EOF
chmod 0600 "$work/config.yml"

echo "Size: $(run --rm "$image" sh -c 'du -sxm / 2>/dev/null | cut -f 1') MB"

# A new repository: the signing key, then the first (empty) index
out=$(run --rm -v "$work:/fdroid" "$image" fdroid update -c --create-key 2>&1) ||
	fail "fdroid update -c --create-key: $out"
[ -f "$work/keystore.p12" ] || fail "no keystore.p12"
echo "Key and first index: OK"

# The default command, with the mounts it expects
cp ".cache/$apk" "$work/repo/"
run -d --name "$name" -v "$work:/fdroid" -v "$work/repo:/var/www/html/repo:ro" "$image" >/dev/null
seconds=0
until "$container" logs "$name" 2>&1 | grep -q 'INFO: Finished'; do
	[ "$("$container" inspect -f '{{.State.Running}}' "$name")" = true ] ||
		fail "the default command stopped: $("$container" logs "$name" 2>&1 | tail -n 20)"
	seconds=$((seconds + 1))
	[ "$seconds" -lt 300 ] || fail "fdroid update -c didn't finish in 300 s"
	sleep 1
done
in_container python3 -c 'import json, sys; sys.exit("org.fdroid.fdroid.privileged" not in json.load(open("repo/index-v2.json"))["packages"])' ||
	fail "the APK isn't in repo/index-v2.json"
in_container jarsigner -verify repo/entry.jar | grep -q 'jar verified' || fail "repo/entry.jar isn't signed"
echo "APK indexed, index signed: OK"

get() { in_container busybox wget -S -O /dev/null "http://127.0.0.1/$1" 2>&1; }
served() {
	headers=$(get "$1") || fail "GET /$1: $headers"
	echo "$headers" | grep -qi "content-type: $2" || fail "GET /$1: Content-Type isn't $2"
}
served repo/ text/html
served repo/entry.jar application/java-archive
served repo/index-v2.json application/json
served "repo/$apk" application/vnd.android.package-archive
for secret in config.yml keystore.p12 repo/../config.yml; do
	if get "$secret" >/dev/null; then fail "GET /$secret: served"; fi
done
echo "HTTP: repo/ served, config.yml and keystore.p12 not: OK"

"$container" stop -t 10 "$name" >/dev/null
[ "$("$container" inspect -f '{{.State.ExitCode}}' "$name")" = 0 ] || fail "no clean exit on SIGTERM"
echo "Stop on SIGTERM: OK"
