#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# merge_pat.sh
#   - Synology DSM result.json에서 url/sum을 추출
#   - 모델명 추출 규칙 적용: 파일명 'DSM_<MODEL>_<BUILD>.pat'에서
#       * 앞 'DSM_' 제거
#       * 뒤 '_<digits>.pat' 제거 (예: '_81180.pat')
#       * '%2B' 또는 '%2b' → '+' 로 복원
#   - pats.json에 존재하는 모델에 한해 DSM_VERSION 블록을 "맨 앞"으로 삽입
#   - 동일 버전 키가 이미 있으면 덮어쓰며 선두로 재배치
#   - 최종 출력: 상위 모델 키 알파벳 정렬
#
# Usage:
#   ./merge_pat.sh <pats_file> <result_file> <dsm_version> <output_file>
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
DSM_VERSION="$3"
OUTPUT_FILE="$4"

echo "[INFO] RESULT_FILE : $RESULT_FILE"
echo "[INFO] DSM_VERSION : $DSM_VERSION"
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

# PATS 파일은 반드시 올바른 JSON이어야 함
pats_type=$(jq -r 'type' "$PATS_FILE" 2>/dev/null || echo "invalid")
if [ "$pats_type" != "object" ]; then
  echo "[ERROR] PATS_FILE은 최상위가 JSON object 이어야 합니다."
  exit 1
fi

# ---------- 작업용 임시 파일 ----------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
TMP_JSON="$WORKDIR/pats.tmp.json"
cp "$PATS_FILE" "$TMP_JSON"

PAIRS_TSV="$WORKDIR/pairs.tsv"

# ---------- result.json에서 url/sum 페어 추출 ----------
# 1) 정상 JSON일 때: 중첩을 모두 뒤져 url/sum 가진 object를 찾는다
set +e
jq -r '.. | objects | select(has("url") and has("sum")) | "\(.url)\t\(.sum)"' \
   "$RESULT_FILE" > "$PAIRS_TSV" 2>/dev/null
jq_status=$?
set -e

# 2) 비정상 JSON(키 중복, 구문 깨짐 등)일 때: raw fallback 파서 사용
if [ $jq_status -ne 0 ] || [ ! -s "$PAIRS_TSV" ]; then
  echo "[WARN] RESULT_FILE이 정상 JSON이 아니거나 url/sum 추출이 비어 fallback 파서를 사용합니다."
  # url 다음 줄의 sum을 짝지어 추출 (원문 result.json 형태 대응)
  awk -v IGNORECASE=1 '
    /"url"[[:space:]]*:/ {
      # url 값 추출
      if (match($0, /"url"[[:space:]]*:[[:space:]]*"([^"]+)"/, a)) {
        url=a[1]
      }
      next
    }
    /"sum"[[:space:]]*:/ {
      # sum 값 추출 → url과 페어로 출력
      if (match($0, /"sum"[[:space:]]*:[[:space:]]*"([0-9a-fA-F]{32})"/, b)) {
        sum=b[1]
        if (length(url) > 0) {
          # 소문자화
          for(i=1;i<=length(sum);i++){}
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

# ---------- 유틸리티: 모델명 도출 함수 (Bash) ----------
# 입력: URL 문자열
# 출력: 표준출력으로 모델명 (예: DS1019+)
derive_model() {
  local url="$1"
  # 파일명만 추출
  local fname="${url##*/}"          # DSM_DS1019%2B_81180.pat
  # 앞 'DSM_' 제거
  fname="${fname#DSM_}"             # DS1019%2B_81180.pat
  # 뒤 '_<digits>.pat' 제거
  fname="$(echo -n "$fname" | sed -E 's/_[0-9]+\.pat$//')"  # DS1019%2B
  # '%2B' 또는 '%2b' → '+'
  fname="$(echo -n "$fname" | sed -E 's/%2[Bb]/+/g')"
  printf '%s' "$fname"
}

# ---------- 메인 루프: 페어를 돌며 pats.json 업데이트 ----------
# 선두 삽입 규칙:
#   .[model] = ({(ver): {url,sum}} + (.[model] | with_entries(select(.key != ver))))
#   => 동일 버전 키가 있었던 경우 제거 후 새 블록을 선두에 재삽입
line_no=0
while IFS=$'\t' read -r url sum; do
  line_no=$((line_no+1))
  [ -n "$url" ] || continue
  [ -n "$sum" ] || continue

  model="$(derive_model "$url")"
  if [ -z "$model" ]; then
    echo "[WARN] ($line_no) 모델명 파싱 실패: $url"
    continue
  fi

  # pats에 해당 모델이 존재하는지 확인
  if ! jq -e --arg m "$model" 'has($m)' "$TMP_JSON" >/dev/null; then
    # 존재하지 않으면 무시
    #echo "[DEBUG] ($line_no) 모델 미존재, 건너뜀: $model"
    continue
  fi

  # 업데이트 적용 (선두에 DSM_VERSION 추가)
  jq --arg m "$model" \
     --arg v "$DSM_VERSION" \
     --arg u "$url" \
     --arg s "$(echo -n "$sum" | tr 'A-F' 'a-f')" \
     '
     . as $root
     | ($root[$m]) as $versions
     | $root
     | .[$m] = ( {($v): {url: $u, sum: $s}}
                 + ( $versions | with_entries(select(.key != $v)) ) )
     ' "$TMP_JSON" > "$TMP_JSON.updated"

  mv "$TMP_JSON.updated" "$TMP_JSON"
done < "$PAIRS_TSV"

# ---------- 최종 알파벳 정렬 및 저장 ----------
jq 'to_entries | sort_by(.key) | from_entries' "$TMP_JSON" > "$OUTPUT_FILE"

echo "[INFO] 완료: $OUTPUT_FILE"
