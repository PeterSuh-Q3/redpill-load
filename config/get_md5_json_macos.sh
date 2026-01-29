#!/bin/bash
DSM_VERSION="${1:-7.3.1-86003}"
# macOS 호환 Synology DSM PAT File MD5 Generator
# .md5 파일을 다운로드하여 MD5 값을 직접 추출하는 버전
# md5list 파일에 PAT URL 목록 필요 (첨부된 인덱스 기반으로 생성)
# [https://archive.synology.com/download/Os/DSM/7.3.1-86003](https://archive.synology.com/download/Os/DSM/7.3.1-86003)

# 색상 정의 (macOS 호환)
RED='\\033[0;31m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
BLUE='\\033[0;34m'
NC='\\033[0m' # No Color

# 설정
MAX_PARALLEL=5  # 병렬 증가 (작은 .md5 파일이므로)
RETRY_COUNT=3
TEMP_DIR="temp_md5"
BASE_URL="https://archive.synology.com/download/Os/DSM/7.3.1-86003"

echo -e "${BLUE}Synology DSM PAT MD5 Extractor (from .md5 files, macOS)${NC}"
echo "==============================================="

# 필수 도구 확인
check_dependencies() {
    local missing=()

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        missing+=("curl or wget")
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${RED}Error: Missing required tools: ${missing[*]}${NC}"
        echo "Please install: brew install wget"
        exit 1
    fi
}

# MD5 추출 함수 (.md5 파일 형식: "md5_hash  filename.pat")
extract_md5_from_file() {
    local md5_file="$1"
    local pat_filename="$2"
    
    if [ ! -f "$md5_file" ] || [ ! -s "$md5_file" ]; then
        echo "EXTRACT_FAILED"
        return 1
    fi
    
    # md5 파일에서 해당 pat 파일의 MD5 추출 (첫 번째 단어)
    local md5_hash=$(grep "$pat_filename" "$md5_file" 2>/dev/null | awk '{print $1}' | head -1)
    
    if [ -n "$md5_hash" ] && [[ "$md5_hash" =~ ^[a-f0-9]{32}$ ]]; then
        echo "$md5_hash"
        return 0
    fi
    
    echo "MD5_NOT_FOUND_IN_FILE"
    return 1
}

# .md5 파일 다운로드 함수
download_md5_file() {
    local pat_url="$1"
    local md5_url="${pat_url%.pat}.pat.md5"
    local output="$2"

    if command -v wget >/dev/null 2>&1; then
        wget -q --timeout=30 --tries=1 --content-disposition "$md5_url" -O "$output"
    elif command -v curl >/dev/null 2>&1; then
        curl -f -L --max-time 30 --retry 1 -s "$md5_url" -o "$output"
    fi

    # 파일 크기 확인 (빈 파일 제외)
    local size=$(stat -f%z "$output" 2>/dev/null || stat -c%s "$output" 2>/dev/null || echo "0")
    if [ "$size" -lt 100 ]; then  # 최소 100바이트
        rm -f "$output"
        return 1
    fi
    return 0
}

download_with_retries_md5() {
    local pat_url="$1"
    local out="$2"
    local max_attempts=3
    local attempt=1
    local wait=1

    while [ $attempt -le $max_attempts ]; do
        echo "  Attempt $attempt/$max_attempts: Downloading .md5..."
        if download_md5_file "$pat_url" "$out"; then
            echo "  MD5 file download succeeded"
            return 0
        fi
        echo "  MD5 download failed (attempt $attempt)"
        sleep $wait
        wait=$((wait * 2))
        attempt=$((attempt + 1))
    done
    return 1
}

check_dependencies

# md5list 파일 확인 (PAT URL 목록)
if [ ! -f "md5list" ]; then
    echo -e "${RED}Error: md5list 파일을 찾을 수 없습니다.${NC}"
    echo "md5list에 각 줄에 PAT URL (https://...) 을 입력하세요."
    exit 1
fi

# 임시 디렉토리 생성
mkdir -p "$TEMP_DIR"

# 총 라인 수 계산
total_lines=$(grep -c "^https://" md5list 2>/dev/null || wc -l < md5list)

echo -e "${BLUE}총 $total_lines 개의 PAT URL을 처리합니다.${NC}"

# result.json 초기화
echo "{" > result.json

# 단일 URL 처리 함수 (MD5 파일 다운로드 + 추출)
process_url() {
    local pat_url="$1"
    local index="$2"
    local filename=$(basename "$pat_url" .pat)  # DSM_DS1019+_86003 (확장자 제거)
    local pat_filename=$(basename "$pat_url")  # 전체 파일명: DSM_DS1019+_86003.pat
    local model=$(echo "$filename" | sed -E 's/^DSM_//' | sed -E 's/_86003$//')  # 모델명 추출
    local temp_md5_file="$TEMP_DIR/${filename}.md5"
    local json_key="$model"

    echo -e "${YELLOW}[$((index+1))/$total_lines] Processing: $pat_filename (model: $model)${NC}"

    local md5_hash=""
    local attempt=1

    while [ $attempt -le $RETRY_COUNT ]; do
        if download_with_retries_md5 "$pat_url" "$temp_md5_file"; then
            md5_hash=$(extract_md5_from_file "$temp_md5_file" "$pat_filename")
            rm -f "$temp_md5_file"
            if [ "$md5_hash" != "EXTRACT_FAILED" ] && [ "$md5_hash" != "MD5_NOT_FOUND_IN_FILE" ]; then
                echo -e "  ${GREEN}MD5 extracted: $md5_hash${NC}"
                break
            fi
        fi

        attempt=$((attempt+1))
        [ $attempt -le $RETRY_COUNT ] && sleep 1
    done

    if [ -z "$md5_hash" ] || [[ "$md5_hash" =~ ^(EXTRACT_FAILED|MD5_NOT_FOUND_IN_FILE)$ ]]; then
        md5_hash="EXTRACTION_FAILED"
        echo -e "  ${RED}MD5 extraction failed${NC}"
    fi

    # JSON 엔트리 생성
    local temp_json="$TEMP_DIR/entry_$index.json"
    cat > "$temp_json" << EOF
  "$json_key": {
    "url": "$pat_url",
    "sum": "$md5_hash"
  }
EOF

    echo -e "  ${GREEN}Completed: $json_key${NC}"
}

# URL 배열 생성
urls=()
while IFS= read -r url; do
    if [[ "$url" =~ ^https:// ]]; then
        urls+=("$url")
    fi
done < md5list

echo -e "${BLUE}Starting parallel .md5 downloads (max $MAX_PARALLEL concurrent)...${NC}"

# 병렬 처리
for i in "${!urls[@]}"; do
    while [ $(jobs -r 2>/dev/null | wc -l | tr -d ' ') -ge $MAX_PARALLEL ]; do
        sleep 0.5
    done
    process_url "${urls[$i]}" "$i" &
done

# 완료 대기
wait

echo -e "${BLUE}Assembling final JSON...${NC}"

# JSON 조립 (이전과 동일)
printf '{\n' > result.json
first_entry=1
for i in "${!urls[@]}"; do
    temp_json="$TEMP_DIR/entry_$i.json"
    if [ -f "$temp_json" ]; then
        if [ $first_entry -eq 1 ]; then
            cat "$temp_json" >> result.json
            first_entry=0
        else
            printf ',\n' >> result.json
            cat "$temp_json" >> result.json
        fi
        rm -f "$temp_json"
    fi
done
printf '\n}\n' >> result.json

# JSON 유효성 검사 (이전과 동일)
if command -v jq >/dev/null 2>&1; then
    if ! jq empty result.json >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] result.json is invalid JSON${NC}" >&2
        exit 1
    fi
fi

# 정리
rm -rf "$TEMP_DIR"

echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}작업 완료! result.json 생성.${NC}"
echo -e "${GREEN}총 ${#urls[@]} 개 처리.${NC}"

# 성공/실패 카운트
success_count=$(grep -c '"sum": "[a-f0-9]\{32\}"' result.json 2>/dev/null || echo "0")
failed_count=$(grep -c '"sum": "EXTRACTION_FAILED"' result.json 2>/dev/null || echo "0")
echo -e "${GREEN}성공: $success_count${NC}"
echo -e "${RED}실패: $failed_count${NC}"
