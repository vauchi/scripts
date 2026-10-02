#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Are the container base images pinned by digest still what their tag
# points at?
#
# A Dockerfile pins a base image by digest so a re-pointed tag cannot
# change what ships. The price: security patches to the base arrive only
# when someone bumps the digest. This compares each pin with the tag it
# tracks, so a newer base is noticed (vauchi/private#478).
#
# A pin declares the tag it tracks on the line above its FROM:
#
#   # pin-tracks: gcr.io/distroless/base-nossl-debian13:latest
#   FROM gcr.io/distroless/base-nossl-debian13@sha256:af5c…
#
# Usage:
#   check-image-pins.sh [workspace_root]
#
# Exit: 0 every pin is current, or there are none
#       1 a pin is stale, or a digest pin has no pin-tracks line
#       2 a registry could not be asked (offline, auth): those pins are
#         unverified, not stale
#
# CHECK_IMAGE_PINS_RESOLVER names a command to ask instead of the
# registry: `$cmd <image:tag>` prints the digest, or exits non-zero.
# The tests use it.
#
# Portability: POSIX shell + curl. No bash arrays, no GNU-only flags.
set -eu

WORKSPACE_ROOT="${1:-$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)}"
WORKSPACE_ROOT=$(CDPATH='' cd -- "$WORKSPACE_ROOT" && pwd)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

# Prints the value of one key="value" pair of a WWW-Authenticate header.
auth_param() {
    sed -n "s/.*$1=\"\([^\"]*\)\".*/\1/p" "$TMP/challenge"
}

# HEADs the manifest of $1 (registry) $2 (repository) $3 (tag), with the
# bearer token $4 when given. Leaves the headers in $TMP/headers and
# prints the HTTP status.
head_manifest() {
    : > "$TMP/headers"
    if [ -n "${4:-}" ]; then
        code=$(curl -s -I -o /dev/null -D "$TMP/headers" -w '%{http_code}' \
            -H "Accept: $ACCEPT" -H "Authorization: Bearer $4" \
            "https://$1/v2/$2/manifests/$3") || code=000
    else
        code=$(curl -s -I -o /dev/null -D "$TMP/headers" -w '%{http_code}' \
            -H "Accept: $ACCEPT" \
            "https://$1/v2/$2/manifests/$3") || code=000
    fi
    printf '%s' "$code"
}

# Prints the digest the tag reference $1 (image:tag) points at now.
# Returns non-zero, with the reason on stderr, when it cannot find out.
resolve_digest() {
    if [ -n "${CHECK_IMAGE_PINS_RESOLVER:-}" ]; then
        "$CHECK_IMAGE_PINS_RESOLVER" "$1" < /dev/null
        return
    fi

    image=${1%:*}
    tag=${1##*:}
    case "$image" in
        *.*/* | *:*/*)
            registry=${image%%/*}
            repository=${image#*/}
            ;;
        */*)
            registry="registry-1.docker.io"
            repository=$image
            ;;
        *)
            registry="registry-1.docker.io"
            repository=library/$image
            ;;
    esac

    status=$(head_manifest "$registry" "$repository" "$tag")
    if [ "$status" = "401" ]; then
        tr -d '\r' < "$TMP/headers" \
            | awk 'tolower($1) == "www-authenticate:"' > "$TMP/challenge"
        realm=$(auth_param realm)
        service=$(auth_param service)
        scope=$(auth_param scope)
        [ -n "$scope" ] || scope="repository:$repository:pull"
        : > "$TMP/token.json"
        token_status=$(curl -s -o "$TMP/token.json" -w '%{http_code}' \
            "$realm?service=$service&scope=$scope") || token_status=000
        if [ "$token_status" != "200" ]; then
            echo "token request to $realm: HTTP $token_status" >&2
            return 1
        fi
        token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP/token.json")
        status=$(head_manifest "$registry" "$repository" "$tag" "$token")
    fi
    if [ "$status" != "200" ]; then
        echo "manifest of $1: HTTP $status" >&2
        return 1
    fi
    digest=$(tr -d '\r' < "$TMP/headers" \
        | awk 'tolower($1) == "docker-content-digest:" { print $2; exit }')
    if [ -z "$digest" ]; then
        echo "manifest of $1: no Docker-Content-Digest header" >&2
        return 1
    fi
    printf '%s\n' "$digest"
}

# One line per digest-pinned FROM: <dockerfile>|<tracked tag or empty>|<digest>
find "$WORKSPACE_ROOT" -maxdepth 2 -name 'Dockerfile*' -type f \
    ! -path '*/node_modules/*' ! -path '*/target/*' | sort > "$TMP/dockerfiles"
: > "$TMP/pins"
while IFS= read -r dockerfile; do
    awk -v file="$dockerfile" '
        /^FROM[[:space:]].*@sha256:[0-9a-f]+/ {
            tracks = ""
            if (previous ~ /^# pin-tracks:[[:space:]]*[^[:space:]]+/) {
                tracks = previous
                sub(/^# pin-tracks:[[:space:]]*/, "", tracks)
                sub(/[[:space:]].*$/, "", tracks)
            }
            digest = $0
            sub(/^.*@/, "", digest)
            sub(/[[:space:]].*$/, "", digest)
            print file "|" tracks "|" digest
        }
        { previous = $0 }
    ' "$dockerfile" >> "$TMP/pins"
done < "$TMP/dockerfiles"

if [ ! -s "$TMP/pins" ]; then
    echo "  no digest-pinned base images found"
    exit 0
fi

stale=0
unverified=0
while IFS='|' read -r dockerfile tracks pinned; do
    shown=${dockerfile#"$WORKSPACE_ROOT"/}
    if [ -z "$tracks" ]; then
        echo "  UNTRACKED  $shown — digest pin without a '# pin-tracks: image:tag' line above it"
        stale=1
        continue
    fi
    if current=$(resolve_digest "$tracks" 2> "$TMP/reason"); then
        if [ "$current" = "$pinned" ]; then
            echo "  OK         $shown — $tracks"
        else
            echo "  STALE      $shown — $tracks now points at $current, pinned $pinned"
            stale=1
        fi
    else
        echo "  UNVERIFIED $shown — $tracks ($(tr '\n' ' ' < "$TMP/reason" | sed 's/ $//'))"
        unverified=1
    fi
done < "$TMP/pins"

if [ "$stale" -eq 1 ]; then
    echo "  → bump the digest in the Dockerfile to the one shown, in its own MR"
    exit 1
fi
[ "$unverified" -eq 0 ] || exit 2
