export type BingoCell = {
  cell: number;
  question: string;
  confirmed_by: string | null;
  confirmed_at: string | null;
};

export type BingoParticipant = {
  member_id: string;
  name: string;
  email: string;
  marked_count: number;
  completed_lines: number;
  completed_at: string | null;
  suspicious_count: number;
  completion_rank: number | null;
  completion_tied_count: number;
  completed_team_id: string | null;
  completed_team_name: string | null;
  completion_elapsed_seconds: number | null;
};

export type BingoFlag = {
  requester_name: string;
  requester_email: string;
  confirmer_name: string;
  confirmer_email: string;
  cell: number;
  question: string;
  confirmed_at: string;
  reason: string;
};

export type BingoDetails = {
  round_no: number;
  is_current: boolean;
  rounds: BingoRound[];
  status: "draft" | "open" | "closed";
  opens_at: string | null;
  closes_at: string | null;
  closed_at: string | null;
  prize: string;
  board: BingoCell[];
  completed_lines: number;
  completed_at: string | null;
  questions?: string[];
  participants?: BingoParticipant[];
  flags?: BingoFlag[];
};

export type BingoRound = {
  round_no: number;
  status: "draft" | "open" | "closed";
  opens_at: string | null;
  closes_at: string | null;
  closed_at: string | null;
  is_current: boolean;
};

export type BingoResponse = BingoDetails | { status: "hidden" };
export type BingoFeedback = { status: "idle" | "saved" | "error"; message: string };
export type BingoRequest = { token: string; code: string; expires_at: string; cell: number; question: string; round_no: number };
export type BingoRequestFeedback = BingoFeedback & { request?: BingoRequest; qr?: string };
export type BingoConfirmation = { requester_name: string; question: string; cell: number; expires_at: string; round_no: number };
