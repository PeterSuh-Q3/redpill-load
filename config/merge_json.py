#!/usr/bin/env python3

import json
import sys
import os
from pathlib import Path

def merge_json_files(result_file, pats_file, output_file):
    """
    result.json의 URL과 sum 값을 pats_t.json에 7.3.2-86009-0 버전으로 병합
    """
    
    # 파일 존재 확인
    if not Path(result_file).exists():
        print(f"Error: {result_file} 파일을 찾을 수 없습니다", file=sys.stderr)
        return False
    
    if not Path(pats_file).exists():
        print(f"Error: {pats_file} 파일을 찾을 수 없습니다", file=sys.stderr)
        return False
    
    # JSON 파일 로드
    try:
        with open(result_file, 'r', encoding='utf-8') as f:
            result_data = json.load(f)
        
        with open(pats_file, 'r', encoding='utf-8') as f:
            pats_data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"Error: JSON 파싱 오류 - {e}", file=sys.stderr)
        return False
    
    # 병합 처리
    updated_count = 0
    skipped_count = 0
    
    for model, model_data in result_data.items():
        if model in pats_data:
            # pats_t.json에 해당 모델이 있으면 7.3.2-86009-0 엘리먼트 추가
            pats_data[model]["7.3.2-86009-0"] = {
                "url": model_data.get("url"),
                "sum": model_data.get("sum")
            }
            updated_count += 1
        else:
            skipped_count += 1
            print(f"⚠ 경고: {model} 모델이 pats_t.json에 없습니다", file=sys.stderr)
    
    # 결과 저장
    try:
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(pats_data, f, indent=2, ensure_ascii=False)
    except IOError as e:
        print(f"Error: 파일 쓰기 오류 - {e}", file=sys.stderr)
        return False
    
    # 결과 출력
    print("✓ 병합 완료!")
    print(f"  입력 파일: {result_file} ({len(result_data)} 모델)")
    print(f"  기본 파일: {pats_file} ({len(pats_data)} 모델)")
    print(f"  출력 파일: {output_file}")
    print(f"  업데이트: {updated_count} 모델")
    
    if skipped_count > 0:
        print(f"  스킵: {skipped_count} 모델")
    
    # 샘플 데이터 표시
    print("\n샘플 (DS1019+):")
    if "DS1019+" in pats_data:
        print(json.dumps(pats_data["DS1019+"].get("7.3.2-86009-0"), indent=2, ensure_ascii=False))
    
    print("\n샘플 (DS116):")
    if "DS116" in pats_data:
        print(json.dumps(pats_data["DS116"].get("7.3.2-86009-0"), indent=2, ensure_ascii=False))
    
    return True

def main():
    result_file = sys.argv[1] if len(sys.argv) > 1 else "result.json"
    pats_file = sys.argv[2] if len(sys.argv) > 2 else "pats_t.json"
    output_file = sys.argv[3] if len(sys.argv) > 3 else "pats_updated.json"
    
    success = merge_json_files(result_file, pats_file, output_file)
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
