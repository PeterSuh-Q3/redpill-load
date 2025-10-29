#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Usage: $0 <pats_file> <result_file> <dsm_version> <output_file>"
  exit 2
fi

PATS_FILE="$1"
RESULT_FILE="$2"
DSM_VERSION="$3"
OUTPUT_FILE="$4"

echo "RESULT_FILE: $RESULT_FILE"
echo "DSM_VERSION: $DSM_VERSION"
echo "OUTPUT_FILE: $OUTPUT_FILE"

# 입력 파일 검증
if [ ! -f "$PATS_FILE" ]; then
  echo "ERROR: PATS_FILE not found: $PATS_FILE"
  exit 1
fi
if [ ! -f "$RESULT_FILE" ]; then
  echo "ERROR: RESULT_FILE not found: $RESULT_FILE"
  exit 1
fi

echo "DEBUG: Input files validated"

# JSON 유효성 확인
pats_type=$(jq -r 'type' "$PATS_FILE" 2>/dev/null || echo "invalid")
result_type=$(jq -r 'type' "$RESULT_FILE" 2>/dev/null || echo "invalid")

if [ "$pats_type" = "invalid" ] || [ "$result_type" = "invalid" ]; then
  echo "ERROR: One of input files is not valid JSON"
  exit 1
fi

# 기본 병합 규칙: 두 파일이 객체(object)일 경우 오른쪽 파일(RESULT_FILE)이 동일 키를 덮어쓰도록 병합
jq_filter='.[0] as $p | .[1] as $r |
  if ($p|type)=="object" and ($r|type)=="object" then
    $p + $r
  else
    [.[0], .[1]]
  end
'

# jq 실행 결과 캡처
merge_exit=0
jq_output=$(jq -s "$jq_filter" "$PATS_FILE" "$RESULT_FILE" 2>&1) || merge_exit=$?

echo "DEBUG: jq exit code: $merge_exit"

if [ "$merge_exit" -ne 0 ]; then
  echo "ERROR: jq merge failed"
  echo "jq output:"
  echo "$jq_output"
  exit 1
fi

# 출력 파일 작성
printf "%s\n" "$jq_output" > "$OUTPUT_FILE"

if [ ! -f "$OUTPUT_FILE" ]; then
  echo "ERROR: OUTPUT_FILE not created"
  exit 1
fi

echo "DEBUG: Merge succeeded, output: $OUTPUT_FILE"
exit 0