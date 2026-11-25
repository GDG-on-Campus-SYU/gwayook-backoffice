# 개발 문서

| 궁금한 내용 | 문서 |
| --- | --- |
| 로그인 화면을 로컬에서 열기 | [README](../README.md) |
| 개인 테스트 프로젝트에서 Google 로그인, 첫 관리자, 행사 일정 설정하기 | [테스트 환경 설정](setup.md) |
| 체크인·투표·자료 공유 규칙을 코드에서 찾기 | [코드 구조](architecture.md) |
| 참가자·운영진 웹 안내를 수정하거나 PDF를 만들기 | [사용안내 원본과 PDF](guides/README.md) |

## 테스트 실행

저장소 루트에서 의존성을 설치한 뒤 실행합니다.

```sh
pnpm typecheck
pnpm test
pnpm test:sql
pnpm build
```

`typecheck`는 Next.js 라우트 타입을 생성한 뒤 TypeScript를 검사합니다. `test`는 Node.js에서 입력값 처리와 화면에 쓰이는 계산 등을 확인합니다. CI에서는 의존성 검사(`pnpm audit --audit-level high`)도 실행합니다. [CI 설정](../.github/workflows/ci.yml)

`test:sql`은 Docker에서 PostgreSQL 17을 띄우고 임시 DB에 마이그레이션을 순서대로 적용합니다. 첫 실행 때 이미지를 내려받고, 테스트가 끝나면 컨테이너를 정리합니다. 투표와 발표자료 테스트만 고르려면 아래 명령을 사용하세요. 빙고 마이그레이션 전후 검사는 일부 테스트를 골라도 함께 실행됩니다.

```sh
pnpm test:sql vote_attendance.sql presentations.sql
```

SQL 테스트는 합성 계정과 Auth·Storage의 테스트용 스키마를 사용합니다. Google 로그인과 실제 파일 전송까지 확인하려면 [별도 프로젝트를 연결](setup.md)한 뒤 테스트 계정으로 로그인하세요.
