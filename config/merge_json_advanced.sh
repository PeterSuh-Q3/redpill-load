#!/bin/bash

# 고급 쉘 스크립트: JSON 병합 (jq 기반)
# 기능: result.json의 URL과 sum을 pats.json에 7.3.2-86009-0으로 추가
# 의존성: jq

set -euo pipefail

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 함수: 에러 메시지
error() {
    echo -e "${RED}✗ Error: $*${NC}" >&2
    exit 1
}

# 함수: 정보 메시지
info() {
    echo -e "${BLUE}ℹ $*${NC}"
}

# 함수: 성공 메시지
success() {
    echo -e "${GREEN}✓ $*${NC}"
}

# 함수: 경고 메시지
warn() {
    echo -e "${YELLOW}⚠ $*${NC}"
}

# 함수: 사용법 출력
usage() {
    cat << EOF
사용법: $(basename "$0") [옵션]

옵션:
    -r, --result FILE      result.json 파일 경로 (기본: result.json)
    -p, --pats FILE        pats.json 파일 경로 (기본: pats.json)
    -o, --output FILE      출력 파일 경로 (기본: pats_updated.json)
    -v, --version VERSION  DSM 버전 (기본: 7.3.2-86009-0)
    -b, --backup           백업 파일 생성 (기본: 활성화)
    --no-backup            백업 파일 미생성
    -h, --help             이 도움말 출력

예제:
    $(basename "$0") -r result.json -p pats.json -o pats_merged.json
    $(basename "$0") --version 7.3.2-86010-0

EOF
    exit 0
}

# 기본값 설정
RESULT_FILE="result.json"
PATS_FILE="pats.json"
OUTPUT_FILE="pats_updated.json"
VERSION="7.3.2-86009-0"
CREATE_BACKUP=true

# 명령줄 인자 파싱
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--result)
            RESULT_FILE="$2"
            shift 2
            ;;
        -p|--pats)
            PATS_FILE="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        -b|--backup)
            CREATE_BACKUP=true
            shift
            ;;
        --no-backup)
            CREATE_BACKUP=false
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "알 수 없는 옵션: $1"
            ;;
    esac
done

# jq 설치 확인
if ! command -v jq &> /dev/null; then
    error "jq를 찾을 수 없습니다. 먼저 설치해주세요."
fi

# 파일 존재 확인
[[ -f "$RESULT_FILE" ]] || error "$RESULT_FILE 파일을 찾을 수 없습니다"
[[ -f "$PATS_FILE" ]] || error "$PATS_FILE 파일을 찾을 수 없습니다"

# JSON 유효성 검증
info "JSON 유효성 검증 중..."
jq empty "$RESULT_FILE" 2>/dev/null || error "$RESULT_FILE이 유효한 JSON이 아닙니다"
jq empty "$PATS_FILE" 2>/dev/null || error "$PATS_FILE이 유효한 JSON이 아닙니다"
success "JSON 유효성 검증 완료"

# 모델 수 계산
RESULT_MODELS=$(jq 'keys | length' "$RESULT_FILE")
PATS_MODELS=$(jq 'keys | length' "$PATS_FILE")

info "파일 정보:"
echo "  result.json: $RESULT_MODELS 개 모델"
echo "  pats.json: $PATS_MODELS 개 모델"
echo "  병합 버전: $VERSION"

# 백업 파일 생성
if [[ "$CREATE_BACKUP" == true ]]; then
    BACKUP_FILE="${PATS_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$PATS_FILE" "$BACKUP_FILE"
    success "백업 파일 생성: $BACKUP_FILE"
fi

# JSON 병합 실행
info "JSON 병합 중..."

jq --arg version "$VERSION" \
   --slurpfile result "$RESULT_FILE" \
   'reduce (($result[0] | keys[]) as $model;
     .;
     if .[$model] != null then
       .[$model][$version] = {
         "url": $result[0][$model].url,
         "sum": $result[0][$model].sum
       }
     else
       .
     end)' "$PATS_FILE" > "${OUTPUT_FILE}.tmp"

# 임시 파일을 최종 출력 파일로 변경
mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"

success "JSON 병합 완료!"
info "출력 파일: $OUTPUT_FILE"

# 병합 결과 통계
MERGED_COUNT=$(jq --arg version "$VERSION" '[.[] | has($version)] | map(select(.) == true) | length' "$OUTPUT_FILE")
info "업데이트된 모델: $MERGED_COUNT / $RESULT_MODELS"

# 샘플 데이터 표시
echo ""
info "샘플 데이터 (DS1019+):"
jq --arg version "$VERSION" ".\"DS1019+\" | .[$version] // \"정보 없음\"" "$OUTPUT_FILE" | sed 's/^/    /'

echo ""
info "샘플 데이터 (DS1517+):"
jq --arg version "$VERSION" ".\"DS1517+\" | .[$version] // \"정보 없음\"" "$OUTPUT_FILE" | sed 's/^/    /'

# 파일 크기 비교
ORIGINAL_SIZE=$(du -h "$PATS_FILE" | cut -f1)
NEW_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)

info "파일 크기:"
echo "  원본: $ORIGINAL_SIZE"
echo "  새 파일: $NEW_SIZE"

success "모든 작업이 완료되었습니다!"
