export type InventoryTeam = { id: string; name: string };

export const movementLabels = {
  received: "수령",
  issued: "팀에 지급",
  recovered: "팀에서 회수",
  returned: "외부 반납",
  correction: "보관 수량 정정",
} as const;

export type MovementKind = keyof typeof movementLabels;
