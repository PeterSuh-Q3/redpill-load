# Global Preferences
- 한국어로 응답
- 코드 설명은 간결하게, 핵심만
- 커널 오류 분석 순서: RIP → Call Trace → 원인

---

# Redpill LOAD — 작업 컨텍스트

## 한 줄 요약
DSM을 비 Synology 하드웨어에서 실행하기 위한 시놀로지 각 플랫폼별 설정값관리 및 RAMDISK 생성

## 프로젝트 목표
현재 각 플랫폼별 설정파일인 config.json 이
예를 들어 purlaey 인경우
config/purley/7.3.2-86009/config.json 에 존재하는데
이 안에 설정된 synoinfo.conf 파일을 실제 RAMDISK 빌드시 정확히 참조를 못하고 있는것 같다.
이 메커니즘을 분석하고 문제점을 파악하고 필요하면 수정하라.

+ ---
+
+ # Coding Principles (Anthropic Standard)
+

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
