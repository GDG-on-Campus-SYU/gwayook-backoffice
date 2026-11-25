# 테스트 환경 설정

로그인 화면과 약관을 보거나 단위 테스트를 실행할 때는 Supabase 계정이 필요하지 않습니다. [로컬 실행](../README.md) 후 로그인 버튼 대신 설정 안내가 보이면 예상한 상태입니다. 아래 절차는 테스트 계정으로 실제 체크인·제출·투표 화면까지 열어 볼 때 사용합니다.

## 새 테스트 DB 준비

본인이 관리하는 빈 Supabase 프로젝트(PostgreSQL 17)를 만들고 프로젝트 참조 ID를 확인합니다. Supabase CLI v3를 설치한 뒤 저장소 루트에서 다음 명령을 실행하세요. `YOUR_TEST_PROJECT_REF`를 만든 프로젝트의 참조 ID로 바꿉니다. [CLI 설치와 실행](https://supabase.com/docs/guides/local-development/cli/getting-started)

```sh
supabase login
supabase link YOUR_TEST_PROJECT_REF
supabase db push --remote --dry-run
```

출력된 적용 대상이 방금 만든 테스트 프로젝트인지 확인한 뒤 `supabase db push --remote`를 실행합니다. 이 명령이 [마이그레이션](../supabase/migrations)을 적용해 명단·투표 테이블, DB 함수와 비공개 Storage 버킷을 만듭니다. [Supabase CLI v3의 원격 DB 선택](https://supabase.com/changelog/supabase-cli-v3)

## Google과 앱의 콜백 설정

1. Google Cloud에서 테스트용 OAuth 클라이언트(유형 **웹 애플리케이션**)를 만듭니다. 승인된 JavaScript 원본에 `http://localhost:3000`을, 승인된 리디렉션 URI에는 **Supabase의 Google 제공자 화면에 표시된 콜백 URL**을 넣습니다. Google 앱의 게시 상태가 테스트이면 로그인할 계정을 테스트 사용자에 추가합니다.
2. Supabase Auth에서 Google 제공자를 켜고 해당 클라이언트 ID와 비밀 값을 입력합니다. Auth의 URL Configuration에서 Site URL은 `http://localhost:3000`, 허용 Redirect URLs는 `http://localhost:3000/auth/callback`으로 설정합니다. [Google 로그인 설정](https://supabase.com/docs/guides/auth/social-sign-in/auth-google) · [Supabase 리디렉션 URL](https://supabase.com/docs/guides/auth/redirect-urls)
3. 저장소 루트의 [.env.example](../.env.example)을 `.env.local`로 복사하고 아래 값을 채웁니다. 변경 후 `pnpm dev`를 다시 시작합니다.

| 변수 | 넣을 값 |
| --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | 테스트 프로젝트 URL |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | 같은 프로젝트의 publishable key |
| `SUPABASE_SECRET_KEY` | 서버가 발표자료 제출을 처리하고 다운로드 링크를 발급할 때 쓰는 secret key. 서버 환경에만 보관합니다. |
| `APP_URL` | 브라우저에서 열 앱 주소. 로컬 기본값은 `http://localhost:3000`입니다. |

## 첫 총관리자 로그인

테스트 프로젝트의 SQL Editor에서 아래 예시 이메일을 본인이 로그인할 Google 테스트 계정 주소로 바꾸어 실행합니다. 앱은 Google에서 확인된 이메일로 등록 명단을 찾습니다.

```sql
insert into public.members (name, email, role)
values ('테스트 총관리자', 'owner@example.com', 'owner');
```

앱의 [로그인 페이지](http://localhost:3000/login)에서 해당 계정을 선택하고 약관을 확인합니다. 운영 화면의 **설정·기록**에서 행사일과 제출·투표 마감을 테스트할 미래 시각으로 바꿉니다. 참가자 화면도 보려면 **참가자·팀**에서 별도의 Google 테스트 계정을 등록하고 다른 브라우저 프로필에서 로그인하세요.

다른 행사에서 운영하려면 **설정·기록**의 문의처 외에 `/terms`와 `/privacy`의 운영 주체·개인정보 문의 연락처·보관 기간·외부 처리 안내도 해당 행사에 맞게 작성하세요. 고지를 바꾸면 동의 화면과 DB가 같은 버전을 기록하도록 함께 갱신합니다. [약관·개인정보 화면](../app/%28legal%29) · [동의 버전](../lib/privacy.ts) · [DB의 동의 기록](../supabase/migrations/20261116111436_privacy_controls.sql)
