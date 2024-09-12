#!/bin/bash

# 원본과 변경할 디렉토리 이름
old_dir="7.2.2-72803"
new_dir="7.2.2-72806"

# 현재 디렉토리에서 모든 하위 디렉토리 검색
for dir in */$old_dir; do
    if [ -d "$dir" ]; then
        # 새로운 디렉토리 이름 생성
        new_path="${dir/$old_dir/$new_dir}"
        
        # 디렉토리 이름 변경
        mv "$dir" "$new_path"
        
        echo "Renamed $dir to $new_path"
    fi
done
