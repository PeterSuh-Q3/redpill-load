#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/include/kernel-image-routing.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_route() {
  local expected="$1"; shift
  local actual
  actual="$(brp_kernel_route_resolve "$@")" || fail "route unexpectedly rejected: $*"
  [[ "$actual" == "$expected" ]] || fail "route expected $expected, got $actual for: $*"
  pass=$((pass + 1))
}
assert_rejected() {
  if brp_kernel_route_resolve "$@" >/dev/null 2>&1; then fail "route unexpectedly accepted: $*"; fi
  pass=$((pass + 1))
}
assert_asset_rejected() {
  if brp_detourbmi2_resolve_asset "$@" >/dev/null 2>&1; then fail "asset unexpectedly accepted: $*"; fi
  pass=$((pass + 1))
}

# The original module-pack branch remains the default and is independent of CPU
# profile selection. Only an explicit detour profile can select the new route.
assert_route official 5.10.55 7.4 all-modules official
assert_route official 5.10.55 7.4 all-modules ''
assert_route custom 5.10.55 7.4 custom-modules official
assert_route official 4.4.302 6.2 custom-modules official
assert_route detourbmi2 5.10.55+ 7.4 all-modules detourbmi2
assert_route detourbmi2 5.10.55 7.3 all-modules detourbmi2
assert_rejected 5.10.55 7.4 custom-modules detourbmi2
assert_rejected 5.10.55 7.4 anodrm-modules detourbmi2
assert_rejected 4.4.302 7.4 all-modules detourbmi2
assert_rejected 5.10.55 7.2 all-modules detourbmi2
assert_rejected 5.10.55 7.4 all-modules typo
assert_rejected unknown 7.4 all-modules detourbmi2
assert_rejected 5.10.55 unknown all-modules detourbmi2

asset_dir="${tmp}/assets"
mkdir -p "${asset_dir}"
asset_name='bzImage-epyc7002-7.4-5.10.55'
asset_content='test-only bzImage payload'
printf '%s' "$asset_content" > "${asset_dir}/${asset_name}"
asset_sha="$(sha256sum "${asset_dir}/${asset_name}" | awk '{print $1}')"
jq -n --arg sha "$asset_sha" --arg file "$asset_name" '{schema_version:1,assets:[{model:"SA6400",platform:"epyc7002",dsm_release:"7.4.1-90080",kernel_release:"5.10.55+",filename:$file,sha256:$sha}]}' > "${asset_dir}/manifest.json"

manifest_sha="$(sha256sum "${asset_dir}/manifest.json" | awk '{print $1}')"
resolved="$(brp_detourbmi2_resolve_asset "$asset_dir" "$manifest_sha" SA6400 epyc7002 7.4.1-90080 5.10.55+)" \
  || fail 'valid exact asset was rejected'
[[ "$resolved" == "${asset_dir}/${asset_name}" ]] || fail "resolved wrong asset: $resolved"
pass=$((pass + 1))
assert_asset_rejected "$asset_dir" "" SA6400 epyc7002 7.4.1-90080 5.10.55+
assert_asset_rejected "$asset_dir" "$(printf '0%.0s' {1..64})" SA6400 epyc7002 7.4.1-90080 5.10.55+

assert_asset_rejected "${tmp}/missing" "$manifest_sha" SA6400 epyc7002 7.4.1-90080 5.10.55+
assert_asset_rejected "$asset_dir" "$manifest_sha" SA6400 v1000nk 7.4.1-90080 5.10.55+
assert_asset_rejected "$asset_dir" "$manifest_sha" SA6400 epyc7002 7.4.1-90081 5.10.55+
assert_asset_rejected "$asset_dir" "$manifest_sha" DS425+ epyc7002 7.4.1-90080 5.10.55+
resolved="$(brp_detourbmi2_resolve_asset "$asset_dir" "$manifest_sha" SA6400 epyc7002 7.4.1-90080 5.10.55)" \
  || fail 'kernel release without localversion + was rejected'
[[ "$resolved" == "${asset_dir}/${asset_name}" ]] || fail "resolved wrong asset for normalized kernel release: $resolved"
pass=$((pass + 1))

# The installer modifies only the kernel destination; module pack and initrd
# sentinel files remain byte-identical. The production manifest currently uses
# raw bzImage files.
printf 'all-modules sentinel' > "${tmp}/all-modules.tgz"
printf 'initrd sentinel' > "${tmp}/initrd-dsm"
modules_sha="$(sha256sum "${tmp}/all-modules.tgz" | awk '{print $1}')"
initrd_sha="$(sha256sum "${tmp}/initrd-dsm" | awk '{print $1}')"
install_log="$(brp_detourbmi2_install_asset "$asset_dir" "$manifest_sha" SA6400 epyc7002 7.4.1-90080 5.10.55+ "${tmp}/zImage-dsm")" \
  || fail 'valid raw kernel asset failed installation'
[[ "$install_log" == "${asset_dir}/${asset_name}" ]] || fail "installer reported wrong source: $install_log"
cmp -s "${asset_dir}/${asset_name}" "${tmp}/zImage-dsm" || fail 'installed raw kernel differs from source'
[[ "$(sha256sum "${tmp}/all-modules.tgz" | awk '{print $1}')" == "$modules_sha" ]] || fail 'module pack sentinel changed'
[[ "$(sha256sum "${tmp}/initrd-dsm" | awk '{print $1}')" == "$initrd_sha" ]] || fail 'initrd sentinel changed'
pass=$((pass + 1))

# The same installer supports the legacy custom-zImage transport convention:
# gzip input, raw bzImage output, with independent compressed and raw hashes.
gzip_dir="${tmp}/gzip-assets"
mkdir -p "$gzip_dir"
gzip_name="${asset_name}.gz"
gzip -n -c "${tmp}/zImage-dsm" > "${gzip_dir}/${gzip_name}"
gzip_sha="$(sha256sum "${gzip_dir}/${gzip_name}" | awk '{print $1}')"
image_sha="$(sha256sum "${tmp}/zImage-dsm" | awk '{print $1}')"
jq -n --arg sha "$gzip_sha" --arg image_sha "$image_sha" --arg file "$gzip_name" '{schema_version:1,assets:[{model:"SA6400",platform:"epyc7002",dsm_release:"7.4.1-90080",kernel_release:"5.10.55+",filename:$file,sha256:$sha,image_sha256:$image_sha}]}' > "${gzip_dir}/manifest.json"
gzip_manifest_sha="$(sha256sum "${gzip_dir}/manifest.json" | awk '{print $1}')"
gzip_log="$(brp_detourbmi2_install_asset "$gzip_dir" "$gzip_manifest_sha" SA6400 epyc7002 7.4.1-90080 5.10.55+ "${tmp}/zImage-dsm-gzip")" \
  || fail 'valid gzip kernel asset failed installation'
[[ "$gzip_log" == "${gzip_dir}/${gzip_name}" ]] || fail "gzip installer reported wrong source: $gzip_log"
cmp -s "${tmp}/zImage-dsm" "${tmp}/zImage-dsm-gzip" || fail 'gzip kernel output differs after decompression'
pass=$((pass + 1))

# A matching manifest record must not permit a missing or altered payload.
rm "${asset_dir}/${asset_name}"
assert_asset_rejected "$asset_dir" "$manifest_sha" SA6400 epyc7002 7.4.1-90080 5.10.55+
printf '%s' "$asset_content" > "${asset_dir}/${asset_name}"
printf 'tampered' >> "${asset_dir}/${asset_name}"
assert_asset_rejected "$asset_dir" "$manifest_sha" SA6400 epyc7002 7.4.1-90080 5.10.55+

# Ambiguous manifest entries fail closed instead of choosing the first match.
cp "${asset_dir}/${asset_name}" "${tmp}/good-payload"
printf '%s' "$asset_content" > "${asset_dir}/${asset_name}"
jq '.assets += [.assets[0]]' "${asset_dir}/manifest.json" > "${asset_dir}/manifest-duplicate.json"
mv "${asset_dir}/manifest-duplicate.json" "${asset_dir}/manifest.json"
assert_asset_rejected "$asset_dir" "$manifest_sha" SA6400 epyc7002 7.4.1-90080 5.10.55+

echo "PASS: ${pass} kernel routing and asset validation cases"
