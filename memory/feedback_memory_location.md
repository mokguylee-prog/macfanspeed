---
name: feedback-memory-location
description: 메모리 저장 위치 선호도 — 사용자 계정 폴더 사용 금지, 프로젝트 폴더에만 저장
metadata:
  type: feedback
---

메모리는 반드시 해당 프로젝트 폴더 내 `memory/` 디렉토리에만 저장한다.

**Why:** 사용자가 `/Users/kade/.claude/projects/...` 경로(사용자 계정의 Claude 프로젝트 폴더)에 저장되는 것을 원하지 않음. 프로젝트 폴더가 이동/이름 변경되어도 메모리가 프로젝트와 함께 유지되는 것을 선호.

**How to apply:** 새 메모리 파일 작성 시 항상 현재 프로젝트 폴더 내 `memory/` 경로 사용. `/Users/kade/.claude/projects/*/memory/` 경로는 절대 사용하지 않는다.
