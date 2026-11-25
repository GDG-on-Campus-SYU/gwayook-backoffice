export type VoteStatus = "draft" | "scheduled" | "open" | "expired" | "closed" | "published";

export type Candidate = {
  id: string;
  name: string;
  presentation_order: number | null;
  active_member_count?: number;
};

export type VoteResult = {
  team_id: string;
  name: string;
  vote_count: number;
  gemini_bonus: number;
  bingo_bonus: number;
  total_score: number;
  raw_rank: number;
  tied_count: number;
  final_rank: number | null;
  award_name: string | null;
  tie_reason: string | null;
  main_rank?: number;
  main_tied_count?: number;
  runoff_vote_count?: number | null;
};

export type Runoff = {
  id: string;
  status: "open" | "expired" | "closed";
  opens_at: string;
  closes_at: string;
  main_vote_count: number | null;
  main_score: number | null;
  eligible: boolean;
  voted: boolean;
  eligible_count: number | null;
  voted_count: number | null;
  choice_id: string | null;
  candidates: Candidate[];
  results: Pick<VoteResult, "team_id" | "name" | "vote_count" | "raw_rank" | "tied_count">[];
};

export type RunoffGroup = { raw_rank: number; main_score: number; completed: boolean; candidates: Candidate[] };

export type GeminiBonus = {
  team_id: string;
  name: string;
  approved: boolean;
  note: string | null;
  decided_by_name: string | null;
  decided_at: string | null;
};

export type BingoBonus = Pick<VoteResult, "team_id" | "name" | "bingo_bonus">;

export type VoteDetails = {
  status: VoteStatus;
  opens_at: string | null;
  closes_at: string | null;
  eligible: boolean;
  voted: boolean;
  eligible_count: number | null;
  voted_count: number | null;
  own_team_id: string | null;
  choice_id: string | null;
  candidates: Candidate[];
  results: VoteResult[];
  runoff: Runoff | null;
  runoff_groups: RunoffGroup[];
  runoff_history: Runoff[];
};

export const voteStatusLabels: Record<VoteStatus, string> = {
  draft: "준비 중",
  scheduled: "시작 예약됨",
  open: "진행 중",
  expired: "투표 시간 종료",
  closed: "마감",
  published: "결과 공개",
};

export const voteTime = new Intl.DateTimeFormat("ko-KR", {
  timeZone: "Asia/Seoul", dateStyle: "medium", timeStyle: "short",
});

export const teamIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type VoteActionState = { status: "idle" | "saved" | "error"; message: string };
