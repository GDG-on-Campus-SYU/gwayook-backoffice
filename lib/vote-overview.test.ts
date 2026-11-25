import assert from "node:assert/strict";
import test from "node:test";
import { confirmedVoterCount, currentVote, type VoteOverview } from "./vote-overview.ts";

test("home and display use the runoff clock and electorate until final results are published", () => {
  const vote: VoteOverview = { status: "closed", opens_at: "main-start", closes_at: "main-end", voted: true, eligible_count: 50,
    runoff: { status: "open", opens_at: "runoff-start", closes_at: "runoff-end", voted: false, eligible_count: 40 } };
  assert.equal(currentVote(vote).closes_at, "runoff-end");
  assert.equal(currentVote(vote).voted, false);
  assert.equal(currentVote(vote).eligible_count, 40);
  assert.equal(currentVote({ ...vote, status: "published" }).isRunoff, false);
  assert.equal(currentVote({ ...vote, status: "published" }).closes_at, "main-end");
  assert.equal(currentVote({ ...vote, runoff: null }).isRunoff, false);
  assert.equal(vote.closes_at, "main-end");
});

test("starting a vote requires confirmation of exactly one displayed positive voter count", () => {
  const form = new FormData();
  assert.equal(confirmedVoterCount(form), null);
  for (const value of ["yes", "", "0", "-1", "1.5", "3e1", " 3", "2147483648"]) {
    form.set("confirm", value);
    assert.equal(confirmedVoterCount(form), null);
  }
  form.set("confirm", "33");
  assert.equal(confirmedVoterCount(form), 33);
  form.append("confirm", "33");
  assert.equal(confirmedVoterCount(form), null);
});
