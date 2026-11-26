#!/usr/bin/env bash
# Decides what the release workflow should do for one opsmaru_containers
# release, from the public Hex API and the staged endpoints.
#
# Prints GitHub step outputs on stdout:
#   action=bootstrap|wait-staged|docs-only|upload|skip
#   staged_kind=package|docs        (only for wait-staged)
#   approval_url=<url>               (only for wait-staged)
#   verify_attempts=N verify_interval=S
#
# action=bootstrap means the exact initial 0.1.0 release is not publicly
# served yet (or is public without docs). The workflow waits read-only; no
# OIDC exchange and no uploads happen on this path.
#
# A checksum mismatch fails immediately, on the initial release too. Every
# unexpected answer fails closed with no output.
#
# Usage: hex-upload-state.sh VERSION ARCHIVE_SHA
set -euo pipefail

version="${1:?usage: hex-upload-state.sh VERSION ARCHIVE_SHA}"
our_sha="${2:?usage: hex-upload-state.sh VERSION ARCHIVE_SHA}"

package="opsmaru_containers"
api="${HEX_API_URL:-https://hex.pm/api}"
connection_timeout="${HEX_CONNECT_TIMEOUT:-10}"
request_timeout="${HEX_REQUEST_TIMEOUT:-60}"

release_url="${api}/packages/${package}/releases/${version}"
package_url="${api}/packages/${package}"

fail() {
  echo "::error::$*" >&2
  exit 1
}

read_status_and_body() {
  local url="$1"
  local out
  out=$(curl --silent --show-error --output - --write-out '\n%{http_code}' \
    --connect-timeout "${connection_timeout}" --max-time "${request_timeout}" \
    "${url}" 2>/dev/null) || out="000"
  status="${out##*$'\n'}"
  body="${out%$'\n'*}"
}

read_status_and_body "${package_url}"
package_status="${status}"
read_status_and_body "${release_url}"
release_status="${status}"
release_body="${body}"

case "${package_status}" in
  200) ;;
  404) ;;
  *) fail "Hex answered package lookup ${package_status} for ${package}; refusing to guess" ;;
esac
case "${release_status}" in
  200) ;;
  404) ;;
  *) fail "Hex answered release lookup ${release_status} for ${package} ${version}; refusing to guess" ;;
esac

release_checksum=""
has_docs=""
if [ "${release_status}" = "200" ]; then
  release_checksum=$(jq -r '.checksum | select(type == "string" and length > 0)' <<< "${release_body}" 2>/dev/null || true)
  has_docs=$(jq -r '.has_docs | select(type == "boolean")' <<< "${release_body}" 2>/dev/null || true)
  if [ -z "${release_checksum}" ] || [ -z "${has_docs}" ]; then
    fail "release endpoint returned unexpected JSON"
  fi
  if [ "${release_checksum}" != "${our_sha}" ]; then
    fail "Hex already has ${package} ${version} with checksum ${release_checksum}, but this build is ${our_sha}. Refusing to republish or use --replace."
  fi
fi

# Initial bootstrap: any unserved release or missing public docs takes the
# read-only wait path, even when the package endpoint is 200 (Hex completes
# bundled docs before making the release public, so the package can look
# live while approval is still propagating).
if [ "${version}" = "0.1.0" ]; then
  if [ "${release_status}" = "200" ] && [ "${has_docs}" = "true" ]; then
    echo "action=skip"
    echo "verify_attempts=120"
    echo "verify_interval=30"
    exit 0
  fi

  echo "action=bootstrap"
  echo "verify_attempts=120"
  echo "verify_interval=30"
  exit 0
fi

# Later versions: a missing package is never a bootstrap wait.
if [ "${package_status}" = "404" ]; then
  fail "Hex package ${package} does not exist yet; this is not an initial release (0.1.0 only). See .github/release-runbook.md."
fi

staged_state() {
  local suffix="$1"
  local out
  if ! out=$(mise exec -- mix run --no-start --no-compile .github/scripts/hex-staged-state.exs "${version}" "${suffix}" 2>&1); then
    fail "Could not read staged state for ${package} ${version} (${suffix}): $(printf '%s' "${out}" | tail -1)"
  fi
  staged_status=""
  staged_html_url=""
  staged_checksum=""
  while IFS='=' read -r key value; do
    case "${key}" in
      status) staged_status="${value}" ;;
      html_url) staged_html_url="${value}" ;;
      checksum) staged_checksum="${value}" ;;
    esac
  done <<< "${out}"
  [ -n "${staged_status}" ] || fail "Staged state answer was empty; refusing to guess"
}

validate_staged_url() {
  local url="$1"
  case "${url}" in
    https://hex.pm/*) echo "${url}" ;;
    *) echo "https://hex.pm/dashboard/staged-releases" ;;
  esac
}

if [ "${release_status}" = "200" ]; then
  if [ "${has_docs}" = "true" ]; then
    echo "action=skip"
    echo "verify_attempts=120"
    echo "verify_interval=30"
    exit 0
  fi

  # Public release without docs: query the docs staged endpoint.
  staged_state "docs/staged"
  if [ "${staged_status}" = "staged" ] || [ "${staged_status}" = "approved" ]; then
    echo "action=wait-staged"
    echo "staged_kind=docs"
    echo "approval_url=$(validate_staged_url "${staged_html_url}")"
    echo "verify_attempts=120"
    echo "verify_interval=30"
    exit 0
  fi
  if [ "${staged_status}" = "missing" ]; then
    echo "action=docs-only"
    echo "verify_attempts=8"
    echo "verify_interval=10"
    exit 0
  fi
  fail "Unexpected staged answer ${staged_status}; refusing to guess"
fi

# Release not publicly served: query the package staged endpoint.
staged_state "staged"
if [ "${staged_status}" = "staged" ] || [ "${staged_status}" = "approved" ]; then
  if [ -z "${staged_checksum}" ]; then
    fail "Staged release has no checksum; refusing to guess"
  fi
  if [ "${staged_checksum}" != "${our_sha}" ]; then
    fail "Staged release has checksum ${staged_checksum}, but this build is ${our_sha}. Refusing to republish or use --replace."
  fi
  echo "action=wait-staged"
  echo "staged_kind=package"
  echo "approval_url=$(validate_staged_url "${staged_html_url}")"
  echo "verify_attempts=120"
  echo "verify_interval=30"
  exit 0
fi
if [ "${staged_status}" = "missing" ]; then
  echo "action=upload"
  echo "verify_attempts=8"
  echo "verify_interval=10"
  exit 0
fi
fail "Unexpected staged answer ${staged_status}; refusing to guess"
