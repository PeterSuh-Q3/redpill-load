#!/bin/bash

# 스크립트: result.json의 URL과 sum 값을 pats.json에 병합
# 사용법: ./merge_json.sh result.json pats.json output.json

RESULT_FILE="${1:-result.json}"
PATS_FILE="${2:-pats.json}"
OUTPUT_FILE="${3:-pats_updated.json}"

# 파일 존재 여부 확인
if [ ! -f "$RESULT_FILE" ]; then
    echo "Error: $RESULT_FILE 파일을 찾을 수 없습니다"
    exit 1
fi

if [ ! -f "$PATS_FILE" ]; then
    echo "Error: $PATS_FILE 파일을 찾을 수 없습니다"
    exit 1
fi

# jq를 사용하여 JSON 병합
jq --slurpfile result "$RESULT_FILE" \
   'reduce (($result[0] | keys[]) as $model;
     .;
     if .[$model] != null then
       .[$model]["7.3.2-86009-0"] = {
         "url": $result[0][$model].url,
         "sum": $result[0][$model].sum
       }
     else
       .
     end)' "$PATS_FILE" > "$OUTPUT_FILE"

echo "✓ 병합 완료!"
echo "  입력 파일: $RESULT_FILE ($(jq 'keys | length' "$RESULT_FILE") 모델)"
echo "  기본 파일: $PATS_FILE ($(jq 'keys | length' "$PATS_FILE") 모델)"
echo "  출력 파일: $OUTPUT_FILE"
echo ""

# 업데이트된 엔트리 샘플 표시
echo "샘플 (DS1019+):"
jq '.["DS1019+"]["7.3.2-86009-0"]' "$OUTPUT_FILE"
echo ""
echo "샘플 (DS116):"
jq '.["DS116"]["7.3.2-86009-0"]' "$OUTPUT_FILE"
