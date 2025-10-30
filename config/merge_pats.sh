#!/usr/bin/env bash
set -euo pipefail

# DEBUG="1"
if [ "${DEBUG:-}" = "1" ]; then
  set -x
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] python3 not found; install python3 or use gawk fallback."
  exit 1
fi
# -----------------------------------------------------------------------------
# merge_pats.sh (macOS 용)
#   - result.json에서 url/sum 페어 추출 (정상 JSON이면 jq, 아니면 fallback awk)
#   - 모델명 도출: DSM_<MODEL>_<BUILD>.pat
#       * 'DSM_' 제거
#       * '_<digits>.pat' 제거
#       * '%2B' 또는 '%2b' → '+'
#   - 베이스에 존재하는 모델에 한해 DSM_VERSION 블록을 최상단에 삽입
#   - 동일 버전 키 존재 시 덮어쓰기 및 선두로 재배치
#   - 모델 순서 유지(정렬 없음), jq로 pretty-print
#
# Usage:
#   ./merge_pats.sh <pats_file> <result_file> <dsm_version> <output_file>
#
# Dependencies:
#   - jq (https://stedolan.github.io/jq/)
#   - awk (macOS 기본 탑재)
# -----------------------------------------------------------------------------

if [ "$#" -ne 4 ]; then
  echo "Usage: $0 <pats_file> <result_file> <dsm_version> <output_file>"
  exit 2
fi

PATS_FILE="$1"
RESULT_FILE="$2"
DSM_VERSION="$3"
OUTPUT_FILE="$4"

echo "[INFO] PATS_FILE   : $PATS_FILE"
echo "[INFO] RESULT_FILE : $RESULT_FILE"
echo "[INFO] DSM_VERSION : $DSM_VERSION"
echo "[INFO] OUTPUT_FILE : $OUTPUT_FILE"

if ! command -v jq >/dev/null 2>&1; then
  echo "[ERROR] 'jq' not found. Please install jq and retry."
  exit 1
fi
if [ ! -f "$PATS_FILE" ]; then
  echo "[ERROR] PATS_FILE not found: $PATS_FILE"
  exit 1
fi
if [ ! -f "$RESULT_FILE" ]; then
  echo "[ERROR] RESULT_FILE not found: $RESULT_FILE"
  exit 1
fi

pats_type="$(jq -r 'type' "$PATS_FILE" 2>/dev/null || echo "invalid")"
if [ "$pats_type" != "object" ]; then
  echo "[ERROR] PATS_FILE must be a top-level JSON object"
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

TMP_JSON="$WORKDIR/pats.tmp.json"
cp "$PATS_FILE" "$TMP_JSON"

PAIRS_TSV="$WORKDIR/pairs.tsv"

# jq로 모델명(key), url, sum 추출 (이중 레벨 중첩 구조용)
set +e
jq -r '
  to_entries[]
  | .key as $model
  | .value
  | to_entries[]
  | select(.value | type == "object" and has("url") and has("sum"))
  | "\($model)\t\(.value.url)\t\(.value.sum)"
' "$RESULT_FILE" > "$PAIRS_TSV" 2>/dev/null
jq_status=$?
set -e

if [ $jq_status -ne 0 ] || [ ! -s "$PAIRS_TSV" ]; then
  echo "[WARN] result.json is non-standard or empty; using fallback extractor"
  # fallback: URL과 sum만 추출, 모델명은 URL에서 도출
  # fallback: URL과 sum만 추출, 모델명은 URL에서 도출 (Python 사용 — macOS/Ubuntu 공통)
  python3 - <<'PY' > "$PAIRS_TSV"
import re, sys
fn = sys.argv[1] if len(sys.argv) > 1 else None
if not fn:
    fn = "$RESULT_FILE"  # 이 라인은 쉘에서 치환되므로 안전함
url_re = re.compile(r'"url"\s*:\s*"([^"]+)"', re.IGNORECASE)
sum_re = re.compile(r'"sum"\s*:\s*"([0-9a-fA-F]{32})"', re.IGNORECASE)
urls=[]
sums=[]
with open(fn, 'r', encoding='utf-8') as f:
    for line in f:
        u = url_re.search(line)
        if u:
            urls.append(u.group(1))
            continue
        s = sum_re.search(line)
        if s:
            sums.append(s.group(1).lower())
# 두 리스트를 순서대로 매칭(파일 구조에 따라 url 다음에 sum이 오는 형식 가정)
i = 0
j = 0
out = []
while i < len(urls) and j < len(sums):
    out.append(f"{urls[i]}\t{sums[j]}")
    i += 1
    j += 1
# 출력
for l in out:
    sys.stdout.write(l + "\n")
PY
fi

if [ ! -s "$PAIRS_TSV" ]; then
  echo "[ERROR] No url/sum pairs extracted from result.json"
  exit 1
fi

echo "[INFO] Extracted url/sum pairs: $(wc -l < "$PAIRS_TSV" | tr -d ' ')"

# 모델명 도출 함수: URL에서 모델명 추출 (DSM_ 접두사 제거, 빌드 번호 제거, %2B 치환)
derive_model() {
  local url="$1"
  local fname="${url##*/}"              # DSM_SA6400_86003.pat
  fname="${fname#DSM_}"                 # SA6400_86003.pat
  fname="${fname%_*}"                   # SA6400
  fname="$(echo -n "$fname" | sed -E 's/%2[Bb]/+/g')"  # DS1019+ 등 치환
  printf '%s' "$fname"
}

updated_count=0

while IFS=$'\t' read -r url sum; do
  # 모델명이 URL일 수 있으므로 안전하게 도출
  model=$(derive_model "$url")

  jq --arg m "$model" --arg v "$DSM_VERSION" --arg u "$url" --arg s "$sum" '
    . as $root
    | ($root[$m] // {}) as $versions
    | .[$m] = (
        ({($v): {url: $u, sum: $s}}) + ($versions | with_entries(select(.key != $v)))
      )
  ' "$TMP_JSON" > "$TMP_JSON.updated"
  mv "$TMP_JSON.updated" "$TMP_JSON"

  updated_count=$((updated_count + 1))
done < "$PAIRS_TSV"

jq '.' "$TMP_JSON" > "$OUTPUT_FILE"

if ! jq empty "$OUTPUT_FILE" >/dev/null 2>&1; then
  echo "[ERROR] Output is not valid JSON: $OUTPUT_FILE"
  exit 1
fi

echo "[INFO] Updated models: $updated_count"
echo "[INFO] Done: $OUTPUT_FILE"
