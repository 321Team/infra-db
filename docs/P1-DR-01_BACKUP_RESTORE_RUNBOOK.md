# P1-DR-01 PostgreSQL Backup / Restore Runbook — 검토안

작성: 이권욱, CODEX_ASSISTED, 2026-10-08/09 KST. 책임 Lead: 이재환. 연계: [baseline #21](https://github.com/321Team/fds-project-baseline/issues/21), [#11](https://github.com/321Team/fds-project-baseline/issues/11), [infra-db #1](https://github.com/321Team/infra-db/issues/1).

**문서 검토안이며 새 백업·복원·운영 DB 전환을 실행하거나 승인한 기록이 아니다.** 9/29 실행 원본에서 입증한 절차와 향후 재사용할 때 필요한 선행조건을 구분한다. 새 시험은 DB Lead가 대상·시각·명령과 복구 인수를 확정한 뒤 수행한다.

## 1. 현재 확보된 근거와 재사용 한계

- [evidence #67 / 9월 29일 원본](https://github.com/321Team/fds-project-evidence/tree/dfb2521a8de77686c6566e8752899772f61eb8a1/evidence/P1-DR-01/received-20260929T0315Z): PostgreSQL/도구 16.14, custom dump, 격리 DB 복원 rc0, revision 0003·1,209행·동일 행 md5, 복구 DB를 사용한 R02 거래 1건, 원본으로 복귀, 시험 DB 정리. 그 시점의 결과이며 현재 데이터 수·OID·접근정책을 고정하는 값이 아니다.
- [evidence #172 / 10월 8일 DB 변경](https://github.com/321Team/fds-project-evidence/pull/172): Edge E-K3S 정지, `.50` HBA 제거, credential/Secret 회전 이후 상태를 새 실행 기준으로 확인해야 한다. 9/29의 `.50` DB 허용·옛 credential을 복원하지 않는다.
- [9월 27일 보관 결정](https://github.com/321Team/fds-project-baseline/issues/21#issuecomment-5852937013): dump는 비공개 서버 보관, Git에는 URI·해시·권한 및 비민감 로그만 둔다. 9/3 dump의 실제 인계는 별도 미확인이다.
- 이 문서는 단일 DB 논리 복원이다. PostgreSQL 클러스터 전체/PITR, Harbor/etcd DR, 최신 구성의 전체 Rule 회귀 또는 RPO/RTO 수치의 인수를 새로 주장하지 않는다.

## 2. 실행 전에 고정할 입력

| 입력 | 기준·중단 조건 |
|---|---|
| 서버/계정 | 실제 db01의 hostname·주소를 현재 inventory와 대조. 기존 정상 로그인 계정에서 승인된 sudo→postgres peer 인증 사용. 암호·접속 URI 비밀값을 명령줄·로그·Git에 남기지 않음 |
| Source/Target | Source는 승인된 `fdsdb`. Target은 이번 회차 전용 **새 격리 DB 이름**, 기존 DB와 중복 불가. 이름뿐 아니라 생성 후 OID를 보존 |
| 도구 | server_version, pg_dump, pg_restore 경로·버전 기록. 9/29는 모두16.14였으나 새 실행 전 재확인. 호환성 불명확하면 중단 |
| 보관 | 승인된 `/var/lib/pgsql/fds-evidence/` 아래 회차별 새 경로. postgres 소유 디렉터리700·파일600, 여유 공간 확인. 기존 dump 덮어쓰기 금지 |
| 동시 작업 | DB/앱 배포·마이그레이션·부하·다른 복원과 비중첩. 단독 창은 개별 운영 전환 승인을 대신하지 않음 |
| 비교 기준 | 백업과 비교용 값의 동일 데이터 시점을 보장할 방식을 Lead가 고정. 기존 dump는 당시 manifest/원본과 비교. 데이터가 계속 쓰이는 live DB와 후시점 행 수·md5가 다르다는 이유만으로 복원 실패를 판정하지 않음 |
| 운영 전환 | 격리 복원 단계와 분리. 승인된 서비스 중단 한도·관측 주기·마지막 시작 시각·원복 담당/콘솔·원복 이미지/스키마 호환성을 고정하지 못하면 미실행 |

원격 접속이 승인되지 않으면 다른 계정·HBA 예외·TLS 검증 해제로 우회하지 않는다. 새 실행자는 아래 모든 로그에 회차 ID, KST 시작/끝, 정확한 명령, 종료코드를 기록한다. 명령 결과를 파이프로 가공하면서 실제 pg_dump/pg_restore 종료코드를 잃지 않도록 원 출력을 먼저 보관한다.

## 3. 사전 수집 — 읽기 전용

db01에서 승인 계정으로 다음 메타데이터를 확보한다. `psql`은 `-X`와 `ON_ERROR_STOP=1`을 사용하고, Secret·role password 해시·거래 전체 행을 로그로 덤프하지 않는다.

```text
hostname / date -Is / id
pg_dump --version / pg_restore --version
SHOW server_version; SHOW TimeZone;
DB OID·owner·encoding·collation·datallowconn·DB ACL
대상 DB/role 단위 설정, extension·schema·object owner·ACL
alembic_version, 테이블/인덱스/제약 목록과 비교 기준 행 수·집계
DB별 client_addr·세션 수(credential·전체 SQL text 제외)
보관 경로의 소유·권한·용량, 기존 Target 이름 부재
현재 Worker readyz·Pod/Endpoint·MON 기준선
```

9/29 원본의 `datacl=(default)`와 명시 ACL은 문자열이 달라도 실효 권한이 같을 수 있다. 승인된 role 구성·DB ACL·DB/role 설정을 의미 기준으로 비교하고 차이를 기록한다. Source의 `.50` 허용을 새 기준으로 재사용하지 않는다.

## 4. 백업과 원본 봉인

1. 이미 인수된 dump를 사용하는 시험이면 새 백업을 생략하고 그 dump의 수신 해시·출처·시각을 먼저 확인한다. 새로운 백업이 필요한 경우만 승인된 Source에서 `pg_dump -Fc`를 수행한다.
2. 출력 파일을 만드는 **postgres 실행 문맥에서** umask077을 적용한다. 상위 호출자의 umask가 sudo 뒤에도 유지된다고 가정하지 않는다. 생성 위치·파일명이 기존 파일과 겹치지 않는지 확인한다.
3. stderr/stdout·종료코드를 보존한다. rc 비0 또는 경고의 의미가 불명확하면 다음 단계로 가지 않는다.
4. SHA256, 바이트 수, UID/GID/mode, 생성 시각을 기록하고 파일600·상위 디렉터리700을 확인한다. 9/29에 644→600 정정했던 실수를 반복하지 않는다.
5. `pg_restore --list`로 TOC를 확인한다. `pgcrypto`, 스키마·테이블·데이터·제약·인덱스·ACL 등 대상 객체가 기대와 일치하는지 기록한다. TOC 정상은 실제 복원 성공을 뜻하지 않는다.

PostgreSQL 공식 문서에 따르면 pg_dump는 단일 DB를 백업하며 role 같은 클러스터 공통 객체의 전체 백업과 다르다. custom archive에는 pg_restore를 사용한다. [pg_dump 16](https://www.postgresql.org/docs/16/app-pgdump.html).

## 5. 격리 복원과 대조

1. Source의 인코딩·collation·owner 및 필요한 role/extension이 Target에서 만족되는지 확인한다. 필요한 새 권한·확장은 실행자가 임의 생성하지 않고 Lead에게 차이와 최소 변경을 제시한다.
2. 운영 DB와 다른 전용 Target을 생성한다. DB 이름·OID를 즉시 기록하고 모든 후속 연결이 그 Target인지 확인한다. 기존 DB를 `--clean`으로 덮어쓰는 방식은 이 절차에 포함하지 않는다.
3. 승인된 dump와 Target에 대해 `pg_restore --exit-on-error --verbose --dbname=<Target> <dump>`를 실행하고 전체 stdout/stderr와 실제 rc를 보존한다. `--create`는 archive의 DB 이름으로 복원할 수 있으므로 이 격리 경로에서는 사용하지 않는다.
4. DB 자체 ACL·DB/role 설정은 사전 생성한 Target에 `--create` 없이 복원했을 때 자동으로 원본과 같아졌다고 가정하지 않는다. Source/승인 기준과 다시 비교하고 필요한 재적용은 구체적인 SQL·영향을 Lead가 확정한다. [pg_restore 16](https://www.postgresql.org/docs/16/app-pgrestore.html).
5. 동일 비교 기준으로 revision, 각 테이블 행 수, 안정된 키 순서의 데이터 집계, 인덱스·제약·소유자·실효 ACL·extension을 대조한다. 9/29의 전체 행 md5는 당시 데이터 동등성 보조 근거이며 암호학적 진위 보장이나 새 데이터의 기대값이 아니다.
6. rc0 및 의미 대조 일치까지를 **격리 DB 복원 성공**으로 기록한다. 앱 연결·Rule 회귀·운영 전환까지 PASS로 확대하지 않는다.

복원 중 실패하면 반복 복원을 바로 실행하지 않는다. 실패한 전용 Target·로그·중간 상태를 식별해 보존하고 운영 Source의 연결/데이터가 유지되는지 확인한다. 부분 Target의 폐기는 §7의 대상 확인과 Lead 판단 후에만 한다.

## 6. 복구본을 사용하는 E2E — 별도 변경 단계

9/29에는 운영 DB 이름 교체·세션 종료 방식으로 실제 앱을 복구본에 연결했다. **그 과거 허용을 새 회차에 재사용하지 않는다.** 이번 문서 준비 및 10/9 읽기 전용 수집 창에서는 이 단계를 실행하지 않는다.

향후 Lead가 같은 방식 또는 별도 격리 앱 경로를 선택하면 다음을 실행 계획에 고정한다.

1. 원본/복구본의 이름→OID 매핑, 접속 허용 상태, 세션 소유 앱, credential/스키마 호환성 및 확실한 복구 콘솔을 확보한다.
2. 새 운영 쓰기의 처리·손실 방지 방침을 확정한다. 무단으로 세션을 종료하거나 쓰기 유실을 감수하지 않는다.
3. 변경 전 승인받은 순서대로 연결 경로를 전환하고 **앱 세션이 Target OID를 사용함**을 확인한다.
4. 승인된 `SIM_` 식별자의 제한된 요청을 보내 API 결과와 Target DB 저장을 연결한다. 원본에는 시험 거래가 없어야 한다. 이번 E2E가 증명하는 Rule·요청 수·경로를 명시한다.
5. 승인된 중단 조건(오류/readyz/MON 악화, Target 오인, 시간 초과, 예상 외 쓰기)에 도달하면 신규 요청을 멈추고 사전에 고정한 이름/접속 상태·경로를 원래 OID로 복원한다.
6. 성공하더라도 원래 Source로 복귀하고 앱 세션의 원래 OID 재연결, readyz/Pod/Endpoint/MON, 원본 데이터·권한·설정의 변경 여부를 확인한다.

원복 실패 시 이름을 추측해 rename/drop하거나 추가 재시도하지 않는다. 새 쓰기를 통제하고 두 DB·OID·로그를 보존한 채 복구 인수자에게 넘긴다. 승인되지 않은 데이터 삭제·병합으로 원복을 대신하지 않는다.

## 7. 정리와 보관 인계

- 시험 DB 삭제는 **이 회차에서 생성한 OID이고 현재 운영 Source가 아니라는 확인**, 앱 연결 0 및 Lead 정리 판단 후 수행한다. 과거 이름만 보고 `dropdb`하지 않는다.
- 정리 후 Source 이름/OID·접속 허용·앱 연결·readyz/MON을 재확인한다. 시험 프로세스·port-forward 등 자신이 만든 임시 자원만 회수한다.
- dump는 승인된 비공개 보관 위치에 유지한다. Git에 원문을 올리지 않으며 로컬 PC 원본도 수신 검증과 명시적 폐기 결정 전에는 삭제하지 않는다.
- 과거 **9/3 dump 인계**는 별도 기록으로 다음 정보를 받는다. 현재 존재 여부는 이 문서에서 확인하지 않았다.

| 인계 필드 | 필수 기록 |
|---|---|
| 출처 | 원 보관자, 원 경로/파일명, 당시 manifest/증적 참조 |
| 수신 | 인수자, 비공개 대상 URI, KST 시각, 전달 방식 |
| 무결성 | 송신/수신 SHA256·크기 일치, 불일치 시 중단 |
| 보안 | 디렉터리700·파일600, 소유자·접근 가능자 확인 |
| 보존/폐기 | 보존 책임·기한의 기존 합의, PC 사본 폐기 여부와 승인 참조(미확정이면 미확정) |

## 8. 제출 증적과 완료 판정

새 회차가 실제 수행되면 `fds-project-evidence:evidence/P1-DR-01/<새 회차>/`에 다음 비민감 원본·영수증을 연결한다. 서버 원본은 수정하지 않고 단계별 실패를 포함해 보존한다.

1. 승인 범위·실행자·호스트·시간·Runbook/source SHA, 사전 기준선.
2. dump URI·SHA256·크기·권한·도구 버전·backup rc·TOC.
3. Target 이름/OID, restore 명령·rc·로그·구조/데이터/권한 대조.
4. 실행한 경우에만 앱 경로·요청/DB 결과·운영 전환과 원복 증적.
5. 정리·현재 서비스 상태·수신 해시/manifest·민감정보 점검 결과와 한계.

STATIC 문서 작성, RUNTIME 격리 복원, RUNTIME 앱 E2E, REVIEW 증적 검토, MERGE 편입, AC 인수는 별도다. 이 문서의 병합만으로 #21 종결·9/3 dump 인계 완료·새 복원 성공을 선언하지 않는다.
