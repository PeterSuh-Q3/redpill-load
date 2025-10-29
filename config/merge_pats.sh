#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# merge_pats.sh (improved)
#   - Synology DSM result.json에서 url/sum 페어 추출
#   - 모델명 추출 규칙: 'DSM_<MODEL>_<BUILD>.pat'
#       * 앞 'DSM_' 제거
#       * 뒤 '_<digits>.pat' 제거 (예: '_86003.pat')
#       * '%2B' 또는 '%2b' → '+' 복원
#   - 베이스 pats JSON에 존재하는 모델에 한해 DSM_VERSION_KEY 블록을 "맨 앞"으로 삽입
#   - 동일 버전 키가 이미 있으면 덮어쓴 뒤 선두 재배치
#   - 최종 출력: **모델 순서 보존** (정렬하지 않음)
#
# Usage:
#   ./merge_pats.sh <pats_file> <result_file> <dsm_version> <output_file>
#
# Dependency:
#   - jq (https://stedolan.github.io/jq/)
# -----------------------------------------------------------------------------

if [ "$#" -ne 4 ]; then
  echo "Usage: $0 <pats_file> <result_file> <dsm_version> <output_file>"
  exit 2
fi

PATS_FILE="$1"
RESULT_FILE="$2"
DSM_VERSION_KEY="$3"
OUTPUT_FILE="$4"

echo "[INFO] PATS_FILE   : $PATS_FILE"
echo "[INFO] RESULT_FILE : $RESULT_FILE"
echo "[INFO] DSM_VERSION_KEY : $DSM_VERSION_KEY"
echo "[INFO] OUTPUT_FILE : $OUTPUT_FILE"

# ---------- 입력 파일/명령 검증 ----------
if ! command -v jq >/dev/null 2>&1; then
  echo "[ERROR] 'jq' 명령을 찾을 수 없습니다. 설치 후 다시 시도하세요."
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
# PATS 파일은 반드시 최상위가 object여야 함
pats_type=$(jq -r 'type' "$PATS_FILE" 2>/dev/null || echo "invalid")
if [ "$pats_type" != "object" ]; then
  echo "[ERROR] PATS_FILE 최상위가 JSON object가 아닙니다."
  exit 1
fi

# ---------- 작업용 임시 파일 ----------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
TMP_JSON="$WORKDIR/pats.tmp.json"
cp "$PATS_FILE" "$TMP_JSON"
PAIRS_TSV="$WORKDIR/pairs.tsv"

# ---------- result.json에서 url/sum 페어 추출 ----------
# 1) 정상 JSON일 때: 중첩을 모두 뒤져 url/sum 가진 object 추출
set +e
jq -r '
  .. | objects
  | select(has("url") and has("sum"))
  | "\(.url)\t\(.sum)"
' "$RESULT_FILE" > "$PAIRS_TSV" 2>/dev/null
jq_status=$?
set -e

# 2) 비정상 JSON(중복 키 등)일 때: raw fallback 파서 사용
if [ $jq_status -ne 0 ] || [ ! -s "$PAIRS_TSV" ]; then
  echo "[WARN] RESULT_FILE 파싱이 실패/무결성 부족 → fallback 추출 사용"
  awk -v IGNORECASE=1 '
    /"url"[[:space:]]*:/ {
      if (match($0, /"url"[[:space:]]*:[[:space:]]*"([^"]+)"/, a)) {
        url=a[1]
      }
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
  echo "[ERROR] RESULT_FILE에서 url/sum 페어를 추출하지 못했습니다."
  exit 1
fi

echo "[INFO] 추출된 url/sum 페어 수: $(wc -l < "$PAIRS_TSV" | tr -d ' ')"

# ---------- 유틸리티: 모델명 도출 ----------
derive_model() {
  local url="$1"
  local fname="${url##*/}"          # DSM_DS1019%2B_86003.pat
  fname="${fname#DSM_}"             # DS1019%2B_86003.pat
  fname="$(echo -n "$fname" | sed -E 's/_[0-9]+\.pat$//')" # DS1019%2B
  fname="$(echo -n "$fname" | sed -E 's/%2[Bb]/+/g')"      # DS1019+
  printf '%s' "$fname"
}

# ---------- 메인 루프: 선두 삽입(모델 순서 보존) ----------
line_no=0
updated_count=0

while IFS=$'\t' read -r url sum; do
  line_no=$((line_no+1))
  [ -n "$url" ] || continue
  [ -n "$sum" ] || continue

  model="$(derive_model "$url")"
  if [ -z "$model" ]; then
    echo "[WARN] ($line_no) 모델명 파싱 실패: $url"
    continue
  fi

  # 베이스에 해당 모델이 존재하는지 확인
  if ! jq -e --arg m "$model" 'has($m)' "$TMP_JSON" >/dev/null; then
    # 존재하지 않으면 무시
    continue
  fi

  # 업데이트 적용: DSM_VERSION_KEY을 첫 키로 삽입(동일 키는 제거 후 선두 재배치)
  jq --arg m "$model" \
     --arg v "$DSM_VERSION_KEY" \
     --arg u "$url" \
     --arg s "$(echo -n "$sum" | tr 'A-F' 'a-f')" \
     '
     . as $root
     | ($root[$m]) as $versions
     | .[$m] = ( {($v): {url: $u, sum: $s}}
                 + ( $versions | with_entries(select(.key != $v)) ) )
     ' "$TMP_JSON" > "$TMP_JSON.updated"

  mv "$TMP_JSON.updated" "$TMP_JSON"
  updated_count=$((updated_count+1))
done < "$PAIRS_TSV"

# ---------- 최종 저장(모델 순서 보존, 정렬 없음) ----------
# jq로 포맷만 수행하여 유효 JSON 출력
jq '.' "$TMP_JSON" > "$OUTPUT_FILE"

echo "[INFO] 업데이트된 모델 수: $updated_count"
echo "[INFO] 완료: $OUTPUT_FILE"

# 선택: 간단 검증 (예: 특정 모델 키 맨 앞이 DSM_VERSION_KEY인지 점검하고 싶다면)
# jq -r --arg v "$DSM_VERSION_KEY" 'to_entries[0].key as $first | .["DS1019+"] | keys[0] == $v' "$OUTPUT_FILE"
``
