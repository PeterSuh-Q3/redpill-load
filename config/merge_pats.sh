#!/usr/bin/env bash
set -euo pipefail

DEBUG="1"

# Enable verbose trace when DEBUG=1
if [ "${DEBUG:-}" = "1" ]; then
  set -x
fi

# -----------------------------------------------------------------------------
# merge_pats.sh (improved)
#   - result.json에서 url/sum 페어 추출 (정상 JSON이면 jq, 아니면 fallback awk)
#   - 모델명 도출: DSM_<MODEL>_<BUILD>.pat
#       * 'DSM_' 제거
#       * '_<digits>.pat' 제거
#       * '%2B' 또는 '%2b' → '+'
#   - 베이스에 존재하는 모델에 한해 DSM_VERSION 블록을 "맨 앞"에 삽입
#   - 동일 버전 키가 이미 있으면 덮어쓰며 선두로 재배치
#   - 최종 출력: 모델 순서 보존 (정렬 없음), jq로 pretty-print
#
# Usage:
#   ./merge_pats.sh <pats_file> <result_file> <dsm_version> <output_file>
#
# Dependencies:
#   - jq (https://stedolan.github.io/jq/)
#   - awk (fallback 파서용, macOS/Linux 기본 탑재)
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

# ---------- 사전 점검 ----------
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

# 베이스는 최상위 object 여야 함
pats_type="$(jq -r 'type' "$PATS_FILE" 2>/dev/null || echo "invalid")"
if [ "$pats_type" != "object" ]; then
  echo "[ERROR] PATS_FILE must be a top-level JSON object"
  exit 1
fi

# ---------- 작업 디렉토리 ----------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

TMP_JSON="$WORKDIR/pats.tmp.json"
cp "$PATS_FILE" "$TMP_JSON"

PAIRS_TSV="$WORKDIR/pairs.tsv"

# ---------- result.json에서 url/sum 페어 추출 ----------
# 1) 정상 JSON: 중첩을 모두 순회하여 {"url","sum"} 오브젝트 추출
set +e
jq -r '
  .. | objects
  | select(has("url") and has("sum"))
  | "\(.url)\t\(.sum)"
' "$RESULT_FILE" > "$PAIRS_TSV" 2>/dev/null
jq_status=$?
set -e

# 2) 비정상 JSON(키 중복/구문 오류 등): fallback awk로 라인 스캔
if [ $jq_status -ne 0 ] || [ ! -s "$PAIRS_TSV" ]; then
  echo "[WARN] result.json is non-standard or empty; using fallback extractor"
  awk -v IGNORECASE=1 '
    /"url"[[:space:]]*:/ {
      if (match($0, /"url"[[:space:]]*:[[:space:]]*"([^"]+)"/, a)) { url=a[1] }
      next
    }
    /"sum"[[:space:]]*:/ {
      if (match($0, /"sum"[[:space:]]*:[[:space:]]*"([0-9a-fA-F]{32})"/, b)) {
        sum=b[1]
        if (length(url) > 0) {
          printf "%s\t%s\n", url, tolower(sum)
          url=""
        }
      }
    }
  ' "$RESULT_FILE" > "$PAIRS_TSV"
fi

if [ ! -s "$PAIRS_TSV" ]; then
  echo "[ERROR] No url/sum pairs extracted from result.json"
  exit 1
fi

echo "[INFO] Extracted url/sum pairs: $(wc -l < "$PAIRS_TSV" | tr -d ' ')"

# ---------- 유틸리티: 모델명 도출 ----------
derive_model() {
  # 입력: URL (예: https://.../DSM_DS1019%2B_86003.pat)
  # 출력: 모델명 (예: DS1019+)
  local url="$1"
  local fname="${url##*/}"                           # DSM_DS1019%2B_86003.pat
  fname="${fname#DSM_}"                              # DS1019%2B_86003.pat
  fname="$(echo -n "$fname" | sed -E 's/_[0-9]+\.pat$//')"  # DS1019%2B
  fname="$(echo -n "$fname" | sed -E 's/%2[Bb]/+/g')"       # DS1019+
  printf '%s' "$fname"
}

# ---------- 메인: 각 페어를 적용(모델 순서 보존) ----------
line_no=0
updated_count=0

while IFS=$'\t' read -r url sum; do
  line_no=$((line_no+1))
  [ -n "$url" ] || continue
  [ -n "$sum" ] || continue

  model="$(derive_model "$url")"
  if [ -z "$model" ]; then
    echo "[WARN] ($line_no) model parse failed: $url"
    continue
  fi

  # 베이스에 모델이 존재하는 경우에만 적용
  if ! jq -e --arg m "$model" 'has($m)' "$TMP_JSON" >/dev/null; then
    # 존재하지 않으면 스킵
    continue
  fi

  # 해당 모델 객체의 맨 앞에 DSM_VERSION 키를 삽입 (동일 키 존재 시 제거 후 재배치)
  jq --arg m "$model" \
     --arg v "$DSM_VERSION" \
     --arg u "$url" \
     --arg s "$(echo -n "$sum" | tr 'A-F' 'a-f')" \
     '
     . as $root
     | ($root[$m]) as $versions
     | .[$m] = (
         {($v): {url: $u, sum: $s}}
         + ( $versions | with_entries(select(.key != $v)) )
       )
     ' "$TMP_JSON" > "$TMP_JSON.updated"

  mv "$TMP_JSON.updated" "$TMP_JSON"
  updated_count=$((updated_count+1))
done < "$PAIRS_TSV"

# ---------- 최종 저장: 모델 순서 보존(정렬 없음), 정상 JSON 포맷 ----------
jq '.' "$TMP_JSON" > "$OUTPUT_FILE"

# (선택) 유효성 검사
if ! jq empty "$OUTPUT_FILE" >/dev/null 2>&1; then
  echo "[ERROR] Output is not valid JSON: $OUTPUT_FILE"
  exit 1
fi

echo "[INFO] Updated models: $updated_count"
echo "[INFO] Done: $OUTPUT_FILE"
