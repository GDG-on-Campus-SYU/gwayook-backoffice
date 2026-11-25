"use server";

import { revalidatePath } from "next/cache";
import { requireStaff } from "@/lib/auth";
import { movementLabels } from "./types";

export type InventoryState = { status: "idle" | "saved" | "error"; message: string };

const uuid = /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/i;

function failure(message: string): InventoryState {
  return { status: "error", message };
}

function text(form: FormData, name: string) {
  const value = form.get(name);
  return typeof value === "string" ? value.trim() : "";
}

export async function createItem(_previous: InventoryState, form: FormData): Promise<InventoryState> {
  const { supabase } = await requireStaff();
  const id = text(form, "request_id");
  const name = text(form, "name");
  const source = text(form, "source");
  const memo = text(form, "memo");
  if (!uuid.test(id) || !name || name.length > 100 || !source || source.length > 100 || memo.length > 500) {
    return failure("품목, 차용처, 메모를 확인해 주세요.");
  }

  const { error } = await supabase.rpc("create_inventory_item", {
    p_id: id, p_name: name, p_source: source, p_memo: memo || null,
  });
  if (error) return failure(error.code === "22023" ? error.message : "품목을 저장하지 못했습니다. 다시 시도해 주세요.");
  revalidatePath("/admin", "layout");
  return { status: "saved", message: "품목을 등록했습니다." };
}

export async function recordMovement(_previous: InventoryState, form: FormData): Promise<InventoryState> {
  const { supabase } = await requireStaff();
  const id = text(form, "request_id");
  const item = text(form, "item");
  const kind = text(form, "kind");
  const quantity = text(form, "quantity");
  const team = text(form, "team");
  const reason = text(form, "reason");
  const needsTeam = kind === "issued" || kind === "recovered";
  const count = Number(quantity);
  if (!uuid.test(id) || !uuid.test(item) || !Object.hasOwn(movementLabels, kind) || !/^-?\d{1,5}$/.test(quantity)
    || count === 0 || Math.abs(count) > 10000 || (kind !== "correction" && count < 0)
    || (needsTeam ? !uuid.test(team) : !!team) || (kind === "correction" && !reason) || reason.length > 500) {
    return failure("처리 종류, 수량, 대상 팀, 사유를 확인해 주세요.");
  }

  const { error } = await supabase.rpc("record_inventory_movement", {
    p_id: id, p_item: item, p_kind: kind, p_quantity: count, p_team: team || null, p_reason: reason || null,
  });
  if (error) return failure(error.code === "22023" ? error.message : "수량을 저장하지 못했습니다. 다시 시도해 주세요.");
  revalidatePath("/admin", "layout");
  return { status: "saved", message: "수량을 반영했습니다." };
}
