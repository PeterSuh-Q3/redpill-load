#!/bin/bash

# DSM_VERSION 패턴에 .0 추가하는 함수 (스크립트 맨 위에 추가)
normalize_dsm_version() {
  DSM_VERSION="$1"
  # 패턴: X.Y-##### → X.Y.0-#####
  if [[ "$DSM_VERSION" =~ ^([0-9]+\.[0-9]+)-([0-9]+)$ ]]; then
    DSM_VERSION="${BASH_REMATCH[1]}.0-${BASH_REMATCH[2]}"
  fi
  echo "$DSM_VERSION-0"
}

DSM_VERSION="${1:-7.3.1-86003}"
DSM_VERSION=$(normalize_dsm_version "$DSM_VERSION")
echo "$DSM_VERSION"  # 7.2-64570 → 7.2.0-64570-0

# macOS 호환 Synology DSM PAT File MD5 Generator
# macOS에서 작동하도록 수정된 버전
# md5list 파일 사전준비 필요 A.I gpt5 를 통해 생성가능.(워크플로우 로직으로 대체)
# https://archive.synology.com/download/Os/DSM/7.3.1-86003

# 색상 정의 (macOS 호환)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 설정
MAX_PARALLEL=3  # macOS에서는 좀 더 보수적으로
RETRY_COUNT=2
TEMP_DIR="temp_downloads"

echo -e "${BLUE}Synology DSM PAT File MD5 Generator (macOS)${NC}"
echo "==============================================="

# 필수 도구 확인
check_dependencies() {
    local missing=()

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        missing+=("curl or wget")
    fi

    if ! command -v md5 >/dev/null 2>&1 && ! command -v md5sum >/dev/null 2>&1; then
        missing+=("md5 or md5sum")
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${RED}Error: Missing required tools: ${missing[*]}${NC}"
        echo "Please install missing tools:"
        echo "- For wget: brew install wget"
        echo "- For md5sum: brew install md5sha1sum"
        exit 1
    fi
}

# MD5 계산 함수 (macOS/Linux 호환)
calculate_md5() {
    local file="$1"
    
    # .md5 파일에서 해시값 직접 읽기
    if [ -f "$file" ]; then
        # .md5 파일 포맷: "hash  filename" 또는 "hash filename"
        # 첫 번째 필드(해시)만 추출
        cat "$file" | awk '{print $1}' | head -1
    else
        echo "FILE_NOT_FOUND"
    fi
}

# download_file() 함수 수정 예시 (macOS 버전 기준)
download_file() {
    local url="$1"
    local output="$2"

    # wget 대안 시 --content-disposition 옵션 추가
    if command -v wget >/dev/null 2>&1; then
        if ! wget -q --timeout=60 --tries=1 --content-disposition "$url" -O "$output"; then
            return 1
        fi
    # curl 사용 시 --fail 추가, -L추가로 리다이렉트 허용
    elif command -v curl >/dev/null 2>&1; then
        if ! curl -f -L --max-time 60 --retry 1 -s "$url" -o "$output"; then
            return 1
        fi

    else
        return 1
    fi

    # 다운로드된 파일 크기 확인 (1MB 미만은 에러 처리)
    local min_size=$((1 * 1024 * 1024))
    local actual_size
    actual_size=$(stat -f%z "$output" 2>/dev/null || stat -c%s "$output" 2>/dev/null)
    if [ "$actual_size" -lt "$min_size" ]; then
        rm -f "$output"
        return 1
    fi

    return 0
}

download_with_retries() {
  local url="$1"
  local out="$2"
  local max_attempts=5
  local attempt=1
  local wait=2

  while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt/$max_attempts: Downloading $url"
    # -f: 실패시 non-zero, -S: show error, -L: follow redirect, -s: silent (optional)
    if curl -fSL --retry 2 --retry-delay 5 -o "$out" "$url"; then
      echo "Download succeeded: $out"
      return 0
    fi
    echo "Download failed (attempt $attempt)"
    sleep $wait
    attempt=$((attempt+1))
    wait=$((wait*2))
  done

  echo "All download attempts failed for $url"
  return 1
}

check_dependencies

# md5list 파일 확인
if [ ! -f "md5list" ]; then
    echo -e "${RED}Error: md5list 파일을 찾을 수 없습니다.${NC}"
    exit 1
fi

# 임시 디렉토리 생성
mkdir -p "$TEMP_DIR"

# 총 라인 수 계산 (macOS 호환)
if command -v grep >/dev/null 2>&1; then
    total_lines=$(grep -c "^https://" md5list)
else
    total_lines=$(cat md5list | grep "^https://" | wc -l | tr -d ' ')
fi

echo -e "${BLUE}총 $total_lines 개의 URL을 처리합니다.${NC}"

# result.json 초기화
echo "{" > result.json

# 단일 URL 처리 함수
process_url() {
    local url="$1"
    local index="$2"
    local filename=$(basename "$url")  # 예: DSM_DS1019+_86003.pat

    # 여기서 .md5 를 붙여서 이후 로직 전체에 반영
    url="${url}.md5"

    local filename=$(basename "$url")  # 예: DSM_DS1019+_86003.pat.md5

    # 모델명 추출 (DSM_ 접두사 제거, _ 및 버전 숫자 제거)
    local model=$(echo "$filename" | sed -E 's/^DSM_//' | sed -E 's/_[0-9]+\.pat\.md5$//')

    local temp_file="$TEMP_DIR/$filename"
    local json_key="$model"   # 모델명을 json_key로 사용

    echo -e "${YELLOW}[$((index+1))/$total_lines] Processing: $filename (model: $model)${NC}"

    # 재시도 로직
    local attempt=1
    local md5_hash=""

    while [ $attempt -le $RETRY_COUNT ]; do
        echo "  Attempt $attempt/$RETRY_COUNT: Downloading..."

        if download_with_retries "$url" "$temp_file"; then
            if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
                echo -e "  ${GREEN}Download completed. Calculating MD5...${NC}"
                md5_hash=$(calculate_md5 "$temp_file")
                echo -e "  ${GREEN}MD5: $md5_hash${NC}"
                rm -f "$temp_file"
                break
            else
                echo -e "  ${RED}Downloaded file is empty or missing${NC}"
                rm -f "$temp_file"
            fi
        else
            echo -e "  ${RED}Download failed (attempt $attempt)${NC}"
            rm -f "$temp_file"
        fi

        attempt=$((attempt+1))
        if [ $attempt -le $RETRY_COUNT ]; then
            echo "  Waiting 2 seconds before retry..."
            sleep 2
        fi
    done

    # MD5 값이 없으면 실패로 처리
    if [ -z "$md5_hash" ] || [ "$md5_hash" = "MD5_COMMAND_NOT_FOUND" ]; then
        md5_hash="DOWNLOAD_FAILED"
        echo -e "  ${RED}All download attempts failed${NC}"
    fi

    # JSON 엔트리 생성
    local temp_json="$TEMP_DIR/entry_$index.json"
    local original_url="${url%.md5}"  # .md5 제거
    cat > "$temp_json" << EOF
  "$json_key": {
    "$DSM_VERSION": {
      "url": "$original_url",
      "sum": "$md5_hash"
    }
  }
EOF

    echo -e "  ${GREEN}Completed: $json_key${NC}"
}

# URL 배열 생성
urls=()
while IFS= read -r url; do
    if echo "$url" | grep -q "^https://"; then
        urls+=("$url")
    fi
done < md5list

echo -e "${BLUE}Starting parallel downloads (max $MAX_PARALLEL concurrent)...${NC}"

# 병렬 처리 (macOS에서 jobs 명령어 호환성 고려)
for i in "${!urls[@]}"; do
    # 백그라운드 프로세스 수 제한
    while [ $(jobs -r 2>/dev/null | wc -l | tr -d ' ') -ge $MAX_PARALLEL ]; do
        sleep 1
    done

    process_url "${urls[$i]}" "$i" &
done

# 모든 백그라운드 작업 완료 대기
wait

echo -e "${BLUE}Assembling final JSON...${NC}"

# Create/overwrite result.json
printf '{\n' > result.json
first_entry=1
for i in "${!urls[@]}"; do
    temp_json="$TEMP_DIR/entry_$i.json"

    if [ -f "$temp_json" ]; then
        if [ $first_entry -eq 1 ]; then
            # no leading comma for first entry
            cat "$temp_json" >> result.json
            first_entry=0
        else
            # prepend comma to separate JSON object entries
            printf ',\n' >> result.json
            cat "$temp_json" >> result.json
        fi
        rm -f "$temp_json"
    fi
done

# Close JSON object
printf '\n}\n' >> result.json

# Validate JSON if jq available
if command -v jq >/dev/null 2>&1; then
    if ! jq empty result.json >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] result.json is invalid JSON${NC}" >&2
        echo "PWD: $(pwd)" >&2
        echo "Listing files:" >&2
        ls -alh >&2
        echo "TEMP_DIR contents:" >&2
        ls -alh "$TEMP_DIR" 2>/dev/null || true
        exit 1
    fi
else
    # basic sanity check - strip whitespace from tail to handle trailing newlines
    head_char=$(head -c 1 result.json 2>/dev/null || echo '')
    tail_char=$(tail -c 2 result.json 2>/dev/null | tr -d '\n\r\t ' | tail -c 1 || echo '')
    if [ "$head_char" != '{' ] || [ "$tail_char" != '}' ]; then
        echo -e "${RED}[ERROR] result.json appears malformed (missing braces)${NC}" >&2
        echo "PWD: $(pwd)" >&2
        ls -alh >&2
        exit 1
    fi
fi

# 임시 디렉토리 정리
rm -rf "$TEMP_DIR"

echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}작업 완료! result.json 파일이 생성되었습니다.${NC}"
echo -e "${GREEN}총 ${#urls[@]} 개의 URL을 처리했습니다.${NC}"

# 결과 요약 (macOS grep 호환성)
success_count=$(grep -c '"sum": "[a-f0-9]\{32\}"' result.json 2>/dev/null || echo "0")
failed_count=$(grep -c '"sum": "DOWNLOAD_FAILED"' result.json 2>/dev/null || echo "0")

echo -e "${GREEN}성공: $success_count${NC}"
echo -e "${RED}실패: $failed_count${NC}"
