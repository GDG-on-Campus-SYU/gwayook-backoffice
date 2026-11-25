# 참가자·운영진 사용안내

앱의 `/guide`와 `/admin/guide`는 [같은 안내 원본](../../lib/user-guides.ts)에서 각 역할에 맞는 내용을 읽습니다. 웹 안내는 PDF 없이도 작동합니다. 테스트 프로젝트에서 ‘PDF 보기’까지 사용하려면 아래 절차로 두 파일을 만들어 올리세요.

이 안내는 ZIP 첨부 기능을 추가하기 전에 작성했습니다. 현재 제출할 수 있는 파일과 열람 권한은 [발표자료 제출·공유 규칙](../architecture.md#제출한-파일은-누가-볼-수-있나)을 참고하세요.

## PDF 만들기

[생성 스크립트](../../scripts/build-guide-pdfs.py)는 Windows의 맑은 고딕(`malgun.ttf`, `malgunbd.ttf`)과 Python 패키지 `reportlab`, `pypdf`를 사용합니다. 생성한 PDF에 글꼴을 포함해 배포할 때는 해당 글꼴의 허가 조건을 확인하세요.

두 패키지를 설치한 Python 환경을 활성화한 뒤 저장소 루트에서 PowerShell 7로 실행합니다.

```powershell
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
node --input-type=module -e "import {participantGuide,staffGuide} from './lib/user-guides.ts'; process.stdout.write(JSON.stringify([participantGuide,staffGuide]));" | python scripts/build-guide-pdfs.py
```

생성기는 이 폴더에 `participant-guide.pdf`와 `staff-guide.pdf`를 쓰고, 섹션별 제목·본문과 페이지 수를 검사합니다. 직접 두 파일을 열어 한글 글꼴과 페이지 나눔도 확인하세요.

## 테스트 프로젝트에 올리기

비공개 `event-guides` 버킷에 다음 이름으로 업로드합니다. 파일 하나당 최대 2 MiB입니다.

| 생성 파일 | 버킷 안의 경로 |
| --- | --- |
| `participant-guide.pdf` | `2026-11-21.2/participant.pdf` |
| `staff-guide.pdf` | `2026-11-21.2/staff.pdf` |

앱은 활성 회원에게 참가자 안내를, 운영진과 총관리자에게는 두 안내를 제공합니다. 안내를 개정하면 원본의 `guideRevision`과 [Storage 읽기 정책](../../supabase/migrations/20261121112317_attendance_vote_guide_paths.sql)이 가리키는 경로를 새 버전에 맞추고 PDF를 다시 생성합니다. [PDF 응답 처리](../../app/guide/pdf-response.ts)
