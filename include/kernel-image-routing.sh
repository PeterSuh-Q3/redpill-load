#!/usr/bin/env bash

# Resolve kernel selection independently from the selected module pack.
# Prints exactly one of: official, custom, detourbmi2.
brp_kernel_route_resolve() {
  local kernel_version="$1" dsm_version_mm="$2" module_pack="$3" profile="$4"
  local kernel_major dsm_major dsm_minor

  [[ "${kernel_version}" =~ ^([0-9]+)\. ]] || {
    echo "Invalid kernel version: ${kernel_version}" >&2
    return 2
  }
  kernel_major="${BASH_REMATCH[1]}"
  [[ "${dsm_version_mm}" =~ ^([0-9]+)\.([0-9]+)$ ]] || {
    echo "Invalid DSM version: ${dsm_version_mm}" >&2
    return 2
  }
  dsm_major="${BASH_REMATCH[1]}"
  dsm_minor="${BASH_REMATCH[2]}"

  case "${profile}" in
    ""|official)
      if [[ "${module_pack}" == "custom-modules" ]] && \
         (( kernel_major >= 5 )) && \
         (( dsm_major > 7 || (dsm_major == 7 && dsm_minor >= 3) )); then
        printf '%s\n' custom
      else
        printf '%s\n' official
      fi
      ;;
    detourbmi2)
      [[ "${module_pack}" == "all-modules" ]] || {
        echo "detourbmi2 requires module_pack=all-modules (got ${module_pack:-unset})" >&2
        return 2
      }
      (( kernel_major >= 5 )) || {
        echo "detourbmi2 requires kernel 5.x or newer" >&2
        return 2
      }
      (( dsm_major > 7 || (dsm_major == 7 && dsm_minor >= 3) )) || {
        echo "detourbmi2 requires DSM 7.3 or newer" >&2
        return 2
      }
      printf '%s\n' detourbmi2
      ;;
    *)
      echo "Unsupported kernel profile: ${profile}" >&2
      return 2
      ;;
  esac
}

# Resolve one exact model/platform/DSM/kernel asset from the private asset manifest
# and reject missing, ambiguous, malformed, or corrupted entries.
brp_detourbmi2_resolve_asset() {
  local asset_dir="$1" expected_manifest_sha="$2" model="$3" platform="$4" dsm_release="$5" kernel_release="$6"
  local manifest="${asset_dir}/manifest.json" entry filename expected_sha expected_name asset actual_sha actual_manifest_sha
  local sha_tool="${SHA256SUM_PATH:-sha256sum}" gzip_tool="${GZIP_PATH:-gzip}"
  local dsm_mm kernel_file_version

  [[ -s "${manifest}" ]] || { echo "Missing detourbmi2 manifest: ${manifest}" >&2; return 1; }
  [[ "${expected_manifest_sha}" =~ ^[[:xdigit:]]{64}$ ]] || {
    echo "A pinned detourbmi2 manifest SHA-256 is required" >&2
    return 1
  }
  actual_manifest_sha="$("${sha_tool}" "${manifest}" | awk '{print $1}')" || return 1
  [[ "${actual_manifest_sha}" == "${expected_manifest_sha}" ]] || {
    echo "SHA-256 mismatch for ${manifest}" >&2
    return 1
  }
  [[ "${dsm_release}" =~ ^([0-9]+\.[0-9]+)\..*$ ]] || {
    echo "Invalid DSM release: ${dsm_release}" >&2
    return 1
  }
  dsm_mm="${BASH_REMATCH[1]}"
  [[ "${kernel_release}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)[+]?$ ]] || {
    echo "Invalid kernel release: ${kernel_release}" >&2
    return 1
  }
  kernel_file_version="${BASH_REMATCH[1]}"
  expected_name="bzImage-${platform}-${dsm_mm}-${kernel_file_version}"

  entry="$(jq -er \
    --arg model "${model}" --arg platform "${platform}" \
    --arg dsm_release "${dsm_release}" --arg kernel_release "${kernel_release%+}+" \
    '[.assets[] | select(.model == $model and .platform == $platform and .dsm_release == $dsm_release and .kernel_release == $kernel_release)] | if length == 1 then .[0] else error("expected exactly one asset record") end | [.filename, .sha256] | @tsv' \
    "${manifest}")" || {
      echo "No unique detourbmi2 asset for ${model}/${platform}/${dsm_release}/${kernel_release}" >&2
      return 1
    }
  IFS=$'\t' read -r filename expected_sha <<< "${entry}"
  [[ "${filename}" == "${expected_name}" || "${filename}" == "${expected_name}.gz" ]] || {
    echo "Unexpected detourbmi2 asset filename: ${filename} (expected ${expected_name}[.gz])" >&2
    return 1
  }
  [[ "${expected_sha}" =~ ^[[:xdigit:]]{64}$ ]] || {
    echo "Malformed SHA-256 for ${filename}" >&2
    return 1
  }
  asset="${asset_dir}/${filename}"
  [[ -s "${asset}" ]] || { echo "Missing detourbmi2 image: ${asset}" >&2; return 1; }
  actual_sha="$("${sha_tool}" "${asset}" | awk '{print $1}')" || return 1
  [[ "${actual_sha}" == "${expected_sha}" ]] || {
    echo "SHA-256 mismatch for ${asset}" >&2
    return 1
  }
  if [[ "${filename}" == *.gz ]] && ! "${gzip_tool}" -t "${asset}" >/dev/null 2>&1; then
    echo "Invalid gzip detourbmi2 image: ${asset}" >&2
    return 1
  fi
  printf '%s\n' "${asset}"
}

# Install only the selected kernel image. For compressed payloads, the manifest
# pins both the transported gzip and decompressed bzImage digests.
brp_detourbmi2_install_asset() {
  local asset_dir="$1" manifest_sha="$2" model="$3" platform="$4" dsm_release="$5" kernel_release="$6" destination="$7"
  local manifest="${asset_dir}/manifest.json" asset filename image_sha tmp actual_image_sha
  local sha_tool="${SHA256SUM_PATH:-sha256sum}" gzip_tool="${GZIP_PATH:-gzip}"

  asset="$(brp_detourbmi2_resolve_asset "${asset_dir}" "${manifest_sha}" "${model}" "${platform}" "${dsm_release}" "${kernel_release}")" || return 1
  filename="${asset##*/}"
  tmp="${destination}.tmp.$$"
  rm -f "${tmp}"
  if [[ "${filename}" == *.gz ]]; then
    image_sha="$(jq -er --arg model "${model}" --arg platform "${platform}" --arg dsm_release "${dsm_release}" --arg kernel_release "${kernel_release%+}+" \
      '[.assets[] | select(.model == $model and .platform == $platform and .dsm_release == $dsm_release and .kernel_release == $kernel_release)] | if length == 1 then .[0].image_sha256 // empty else empty end' "${manifest}")" || {
        echo "Compressed detourbmi2 asset lacks a unique uncompressed image_sha256" >&2
        return 1
      }
    [[ "${image_sha}" =~ ^[[:xdigit:]]{64}$ ]] || { echo "Malformed decompressed image SHA-256" >&2; return 1; }
    "${gzip_tool}" -dc "${asset}" > "${tmp}" || { rm -f "${tmp}"; echo "Failed to decompress ${asset}" >&2; return 1; }
  else
    image_sha="$(jq -er --arg model "${model}" --arg platform "${platform}" --arg dsm_release "${dsm_release}" --arg kernel_release "${kernel_release%+}+" \
      '[.assets[] | select(.model == $model and .platform == $platform and .dsm_release == $dsm_release and .kernel_release == $kernel_release)] | if length == 1 then .[0].image_sha256 // .[0].sha256 else empty end' "${manifest}")" || return 1
    cp "${asset}" "${tmp}" || { rm -f "${tmp}"; return 1; }
  fi
  actual_image_sha="$("${sha_tool}" "${tmp}" | awk '{print $1}')" || { rm -f "${tmp}"; return 1; }
  [[ "${actual_image_sha}" == "${image_sha}" ]] || {
    rm -f "${tmp}"
    echo "SHA-256 mismatch for decompressed detourbmi2 image" >&2
    return 1
  }
  mv -f "${tmp}" "${destination}" || { rm -f "${tmp}"; return 1; }
  printf '%s\n' "${asset}"
}
