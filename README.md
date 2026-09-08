# infra-db
321Team FDS 프로젝트의 PostgreSQL 외부 VM 구축·설정·운영 형상관리 저장소. P1-DB-01의 설치 자동화, DB·역할·접근제어 설정, 백업·복구 절차 및 검증 자료를 관리한다.

## 변경 검토 및 승인 절차

`P1-DB-01`의 변경은 다음 순서로 검토·승인한다.

1. **작업 브랜치 및 PR 작성**
   - Lead는 `p1-db-01/<작업명>` 브랜치에서 변경하고 `main`을 대상으로 PR을 작성한다.
   - PR에 연계 티켓, 변경 범위, 검증 결과, 증적 위치 및 검토 대상 **전체 HEAD Commit SHA**를 기록한다.
2. **독립 기술 검토**
   - 작성자와 다른 Reviewer를 지정한다. 작성자는 자신의 변경에 대한 독립 Reviewer를 겸하지 않는다.
   - Reviewer는 해당 HEAD의 변경 내용과 증적을 확인하고, 자신의 GitHub 계정으로 검토 대상 SHA와 **PASS 또는 HOLD**, 판단 근거 및 잔여 조치를 기록한다.
   - Claude는 작성·검토 초안 보조에 사용할 수 있다. 공식 검토 결과는 사람이 직접 확인·제출하며, Bot의 승인만으로 기술 검토를 완료하지 않는다.
3. **변경 후 재검토**
   - 리뷰 이후 커밋이 추가되면 새로운 HEAD SHA를 기준으로 재검토한다.
   - 이전 HEAD에 대한 PASS를 새 HEAD의 승인으로 재사용하지 않는다. HOLD 사항은 조치 후 재검토를 받아야 한다.
4. **최종 승인**
   - 최종 승인자 **이권욱**은 동일 HEAD에 대한 기술 검토 PASS, 검증·증적 및 잔여 조치 상태를 확인한다.
   - PR에 최종 승인 대상 전체 HEAD SHA와 **APPROVED 또는 HOLD**, 판단 근거를 기록한다.
   - 기술 검토 PASS와 최종 승인을 구분하며, 이권욱의 명시적 최종 승인 전에는 병합하지 않는다.
5. **병합 및 기록**
   - 병합 직전에 현재 HEAD가 최종 승인된 SHA와 일치하는지 확인한 후 이권욱이 직접 병합한다.
   - PR 링크, 승인된 HEAD SHA 및 병합 결과 Commit SHA를 기록한다.
   - PR 병합을 실제 DB 서버 반영 승인으로 간주하지 않는다. 서버 반영은 해당 변경의 실행 승인 및 Runbook에 따른다.

### 승인 절차의 적용 방식

- `main` 직접 push, force push 및 최종 승인 전 병합을 운영 규칙으로 금지한다.
- GitHub Free 조직의 Private 저장소에서는 브랜치 보호와 Ruleset 강제를 지원하지 않으므로, 위 절차는 **사람이 준수·확인하는 운영 통제**로 적용한다.
- `Write` 권한에는 push 및 PR 병합 권한이 포함된다. 따라서 “이권욱만 최종 병합”이라는 운영 규칙이 GitHub 권한 설정으로 기술적으로 강제된 상태라고 표시하지 않는다.

기능 지원 범위: [GitHub 브랜치 보호](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/managing-a-branch-protection-rule), [Rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets), [저장소 권한](https://docs.github.com/en/organizations/managing-user-access-to-your-organizations-repositories/managing-repository-roles/repository-roles-for-an-organization).
