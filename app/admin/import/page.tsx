import { RosterImport } from "./roster-import";

export const metadata = { title: "참가자 명단 가져오기" };

export default function RosterImportPage() {
  return (
    <div className="stack">
      <div>
        <h1>참가자 명단 가져오기</h1>
        <p className="muted">구글폼에서 내보낸 엑셀 파일을 선택하고 반영될 변경 사항을 확인하세요.</p>
      </div>
      <RosterImport />
    </div>
  );
}
