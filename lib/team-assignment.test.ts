import assert from "node:assert/strict";
import test from "node:test";
import { parseTeamAssignment, parseTeamRemoval } from "./team-assignment.ts";

const team = "aaaaaaaa-0000-0000-0000-000000000001";
const member = "bbbbbbbb-0000-0000-0000-000000000002";
function input(members: unknown, confirm = false) {
  const form = new FormData();
  form.set("team_id", team.toUpperCase());
  form.set("members", JSON.stringify(members));
  if (confirm) form.set("confirm_move", "on");
  return form;
}

test("bulk team input preserves expected team and requires explicit move confirmation", () => {
  assert.deepEqual(parseTeamAssignment(input([{ id: member.toUpperCase(), expected_team_id: null }])), {
    teamId: team, members: [{ id: member, expected_team_id: null }], confirmMove: false,
  });
  assert.equal(parseTeamAssignment(input([{ id: member, expected_team_id: team }], true))?.confirmMove, true);
});

test("bulk team input rejects duplicate, missing, malformed and oversized selections", () => {
  for (const values of [[], null, {}, [{ id: member }], [{ id: member, expected_team_id: "" }],
    [{ id: "invalid", expected_team_id: null }],
    [{ id: member, expected_team_id: null }, { id: member.toUpperCase(), expected_team_id: null }],
    Array.from({ length: 201 }, () => ({ id: member, expected_team_id: null }))]) {
    assert.equal(parseTeamAssignment(input(values)), null);
  }
  const form = input([{ id: member, expected_team_id: null }]);
  form.set("members", "{");
  assert.equal(parseTeamAssignment(form), null);
  form.set("members", " ".repeat(25_001));
  assert.equal(parseTeamAssignment(form), null);
  form.set("team_id", "");
  assert.equal(parseTeamAssignment(form), null);
});

test("team removal only accepts the displayed team and explicit representative confirmation", () => {
  const form = input([{ id: member, expected_team_id: team }]);
  form.set("expected_representative_id", "");
  assert.deepEqual(parseTeamRemoval(form), {
    teamId: team, members: [{ id: member, expected_team_id: team }], expectedRepresentativeId: null, confirmRepresentative: false,
  });
  form.set("expected_representative_id", member.toUpperCase());
  assert.equal(parseTeamRemoval(form), null);
  form.set("confirm_representative", "true");
  assert.equal(parseTeamRemoval(form), null);
  form.set("confirm_representative", "on");
  assert.equal(parseTeamRemoval(form)?.expectedRepresentativeId, member);
  assert.equal(parseTeamRemoval(form)?.confirmRepresentative, true);
  for (const otherTeam of [null, member]) {
    form.set("members", JSON.stringify([{ id: member, expected_team_id: otherTeam }]));
    assert.equal(parseTeamRemoval(form), null);
  }
  form.set("members", JSON.stringify([{ id: member, expected_team_id: team }]));
  form.set("expected_representative_id", "bad");
  assert.equal(parseTeamRemoval(form), null);
  form.delete("expected_representative_id");
  assert.equal(parseTeamRemoval(form), null);
});
