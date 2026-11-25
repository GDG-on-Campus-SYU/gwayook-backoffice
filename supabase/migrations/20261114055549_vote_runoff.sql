-- Main ballots and event deadlines remain unchanged; each tied score gets one runoff.
create table private.vote_runoffs (
  id uuid primary key default gen_random_uuid(),
  main_vote_count integer not null unique check (main_vote_count >= 0),
  opens_at timestamptz not null default clock_timestamp(),
  closes_at timestamptz not null,
  closed_at timestamptz,
  created_by uuid not null references public.members (id),
  check (isfinite(closes_at) and closes_at > opens_at)
);
create unique index vote_runoffs_one_open on private.vote_runoffs ((true)) where closed_at is null;
create table private.runoff_candidates (
  runoff_id uuid not null references private.vote_runoffs (id),
  team_id uuid not null references private.vote_candidates (team_id),
  primary key (runoff_id, team_id)
);
create table private.runoff_eligibility (
  runoff_id uuid not null references private.vote_runoffs (id),
  member_id uuid not null references private.vote_eligibility (member_id),
  primary key (runoff_id, member_id)
);
create table private.runoff_votes (
  runoff_id uuid not null,
  member_id uuid not null,
  team_id uuid not null,
  updated_at timestamptz not null default clock_timestamp(),
  primary key (runoff_id, member_id),
  foreign key (runoff_id, member_id) references private.runoff_eligibility (runoff_id, member_id),
  foreign key (runoff_id, team_id) references private.runoff_candidates (runoff_id, team_id)
);
create index runoff_votes_candidate on private.runoff_votes (runoff_id, team_id);
create index vote_runoffs_creator on private.vote_runoffs (created_by);
create index runoff_candidates_team on private.runoff_candidates (team_id);
create index runoff_eligibility_member on private.runoff_eligibility (member_id);
alter table private.vote_runoffs enable row level security;
alter table private.runoff_candidates enable row level security;
alter table private.runoff_eligibility enable row level security;
alter table private.runoff_votes enable row level security;
revoke all on private.vote_runoffs, private.runoff_candidates, private.runoff_eligibility, private.runoff_votes
  from public, anon, authenticated, service_role;

alter function private.vote_tally() rename to main_vote_tally;
create function private.runoff_tally(p_runoff_id uuid)
returns table (team_id uuid, name text, vote_count integer, raw_rank integer, tied_count integer)
language sql stable set search_path = '' as $$
  with counts as (
    select c.team_id, c.name, count(v.member_id)::integer as vote_count
    from private.runoff_candidates rc join private.vote_candidates c on c.team_id = rc.team_id
    left join private.runoff_votes v on v.runoff_id = rc.runoff_id and v.team_id = rc.team_id
    where rc.runoff_id = p_runoff_id group by c.team_id, c.name
  )
  select c.team_id, c.name, c.vote_count,
    rank() over (order by c.vote_count desc)::integer,
    count(*) over (partition by c.vote_count)::integer from counts c;
$$;

create function private.vote_tally()
returns table (team_id uuid, name text, vote_count integer, raw_rank integer, tied_count integer)
language sql stable set search_path = '' as $$
  with scores as (
    select m.*, coalesce(r.vote_count, 0) as runoff_count
    from private.main_vote_tally() m
    left join private.vote_runoffs vr on vr.main_vote_count = m.vote_count and vr.closed_at is not null
    left join lateral private.runoff_tally(vr.id) r on r.team_id = m.team_id
  )
  select s.team_id, s.name, s.vote_count,
    rank() over (order by s.vote_count desc, s.runoff_count desc)::integer,
    count(*) over (partition by s.vote_count, s.runoff_count)::integer from scores s;
$$;

create function private.manage_runoff(p_action text, p_candidate_ids uuid[], p_closes_at timestamptz, p_runoff_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  event public.event_settings;
  round private.vote_runoffs;
  action_at timestamptz;
  score integer;
  tied integer;
begin
  if actor.id is null or actor.role <> 'owner' then
    raise exception '총관리자 권한이 필요합니다.' using errcode = '42501';
  end if;
  select * into strict event from public.event_settings where id for update;
  actor := private.current_member();
  if actor.id is null or actor.role <> 'owner' then
    raise exception '총관리자 권한이 필요합니다.' using errcode = '42501';
  end if;
  action_at := clock_timestamp();
  if event.vote_status <> 'closed' then
    raise exception '본투표 마감을 확정한 뒤, 결과 공개 전에만 재투표를 진행할 수 있습니다.' using errcode = '22023';
  end if;
  case p_action
    when 'start' then
      if exists (select 1 from private.vote_runoffs where closed_at is null) then
        raise exception '진행 중인 재투표의 마감을 먼저 확정해 주세요.' using errcode = '22023';
      end if;
      if p_closes_at is null or not isfinite(p_closes_at) or p_closes_at <= action_at then
        raise exception '현재 시각 이후의 재투표 마감을 입력해 주세요.' using errcode = '22023';
      end if;
      if coalesce(cardinality(p_candidate_ids), 0) not between 2 and 200 then
        raise exception '동점 팀을 2개 이상 선택해 주세요.' using errcode = '22023';
      end if;
      select vote_count, tied_count into score, tied from private.main_vote_tally() where team_id = p_candidate_ids[1];
      if score is null or tied <> cardinality(p_candidate_ids) or
        (select count(*) from private.main_vote_tally() where vote_count = score and team_id = any(p_candidate_ids)) <> tied then
        raise exception '본투표에서 같은 득표수인 동점 팀 전체를 선택해 주세요.' using errcode = '22023';
      end if;
      if exists (select 1 from private.vote_runoffs where main_vote_count = score) then
        raise exception '이 동점 그룹은 이미 재투표했습니다. 다시 동점이면 사유를 적어 최종 순위를 정해 주세요.' using errcode = '22023';
      end if;
      insert into private.vote_runoffs (main_vote_count, opens_at, closes_at, created_by)
        values (score, action_at, p_closes_at, actor.id) returning * into round;
      insert into private.runoff_candidates (runoff_id, team_id) select round.id, unnest(p_candidate_ids);
      insert into private.runoff_eligibility (runoff_id, member_id)
        select round.id, member_id from private.vote_eligibility where not (team_id = any(p_candidate_ids));
      if not found then
        raise exception '후보팀 소속을 제외하면 유권자가 없습니다. 동점 결정 사유를 적어 순위를 정해 주세요.' using errcode = '22023';
      end if;
    when 'close' then
      select * into round from private.vote_runoffs where id = p_runoff_id;
      if not found or round.closed_at is not null then
        raise exception '진행 중인 재투표만 마감할 수 있습니다.' using errcode = '22023';
      end if;
      update private.vote_runoffs set closed_at = action_at where id = round.id;
    else raise exception '재투표 작업을 다시 선택해 주세요.' using errcode = '22023';
  end case;
  insert into public.audit_logs (actor_id, action, details) values (actor.id, 'runoff_' || p_action,
    jsonb_build_object('runoff_id', round.id, 'main_vote_count', round.main_vote_count, 'closes_at', round.closes_at));
end;
$$;

create function private.cast_runoff_vote(p_runoff_id uuid, p_team_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  event public.event_settings;
  round private.vote_runoffs;
  action_at timestamptz;
begin
  if actor.id is null or actor.role <> 'participant' then
    raise exception '참가자에게만 투표권이 있습니다.' using errcode = '42501';
  end if;
  select * into strict event from public.event_settings where id for update;
  actor := private.current_member();
  if actor.id is null or actor.role <> 'participant' then
    raise exception '참가자에게만 투표권이 있습니다.' using errcode = '42501';
  end if;
  select * into round from private.vote_runoffs where id = p_runoff_id;
  action_at := clock_timestamp();
  if round.id is null or event.vote_status <> 'closed' or round.closed_at is not null
    or round.opens_at > action_at or round.closes_at <= action_at then
    raise exception '지금은 재투표할 수 없습니다.' using errcode = '22023';
  end if;
  if not exists (select 1 from private.runoff_eligibility where runoff_id = round.id and member_id = actor.id) then
    raise exception '재투표는 본투표 유권자 중 동점 후보팀 소속을 제외하고 참여합니다.' using errcode = '42501';
  end if;
  if not exists (select 1 from private.runoff_candidates where runoff_id = round.id and team_id = p_team_id) then
    raise exception '재투표 후보 팀을 다시 선택해 주세요.' using errcode = '22023';
  end if;
  insert into private.runoff_votes (runoff_id, member_id, team_id) values (round.id, actor.id, p_team_id)
    on conflict (runoff_id, member_id) do update set team_id = excluded.team_id, updated_at = clock_timestamp()
    where runoff_votes.team_id is distinct from excluded.team_id;
end;
$$;

create function private.get_runoff(p_runoff_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  round private.vote_runoffs;
  result jsonb;
  tally jsonb := '[]';
begin
  if actor.id is null then raise exception '행사 명단에 등록된 계정이 필요합니다.' using errcode = '42501'; end if;
  select * into round from private.vote_runoffs where id = p_runoff_id;
  if not found then return null; end if;
  if round.closed_at is not null and (actor.role in ('owner', 'staff') or
    exists (select 1 from public.event_settings where id and vote_status = 'published')) then
    select coalesce(jsonb_agg(to_jsonb(t) order by t.raw_rank, t.name, t.team_id), '[]') into tally
      from private.runoff_tally(round.id) t;
  end if;
  select jsonb_build_object(
    'id', round.id, 'status', case when round.closed_at is not null then 'closed'
      when round.closes_at <= clock_timestamp() then 'expired' else 'open' end,
    'opens_at', round.opens_at, 'closes_at', least(round.closes_at, round.closed_at),
    'main_vote_count', round.main_vote_count,
    'eligible', actor.role = 'participant' and exists (select 1 from private.runoff_eligibility where runoff_id = round.id and member_id = actor.id),
    'voted', actor.role = 'participant' and exists (select 1 from private.runoff_votes where runoff_id = round.id and member_id = actor.id),
    'eligible_count', case when actor.role in ('owner', 'staff') then (select count(*) from private.runoff_eligibility where runoff_id = round.id) end,
    'voted_count', case when actor.role in ('owner', 'staff') then (select count(*) from private.runoff_votes where runoff_id = round.id) end,
    'choice_id', case when actor.role = 'participant' then (select team_id from private.runoff_votes where runoff_id = round.id and member_id = actor.id) end,
    'candidates', (select jsonb_agg(jsonb_build_object('id', c.team_id, 'name', c.name, 'presentation_order', c.presentation_order)
      order by c.presentation_order nulls last, c.name, c.team_id) from private.runoff_candidates rc
      join private.vote_candidates c on c.team_id = rc.team_id where rc.runoff_id = round.id),
    'results', tally
  ) into result;
  return result;
end;
$$;

alter function private.get_vote_overview() rename to get_main_vote_overview;
create function private.get_vote_overview() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  result jsonb := private.get_main_vote_overview();
  runoff jsonb;
begin
  select private.get_runoff(id) into runoff from private.vote_runoffs order by opens_at desc, id desc limit 1;
  return result || jsonb_build_object('runoff', runoff - 'candidates' - 'choice_id' - 'results');
end;
$$;

alter function private.get_vote_details() rename to get_main_vote_details;
create function private.get_vote_details() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  result jsonb := private.get_main_vote_details();
  runoff jsonb;
  groups jsonb := '[]';
  history jsonb := '[]';
  results jsonb := '[]';
begin
  select private.get_runoff(id) into runoff from private.vote_runoffs order by opens_at desc, id desc limit 1;
  if actor.role in ('owner', 'staff') and result->>'status' = 'closed' then
    select coalesce(jsonb_agg(to_jsonb(g) order by g.raw_rank), '[]') into groups from (
      select min(m.raw_rank) as raw_rank, m.vote_count,
        exists (select 1 from private.vote_runoffs vr where vr.main_vote_count = m.vote_count) as completed,
        jsonb_agg(jsonb_build_object('id', m.team_id, 'name', m.name, 'presentation_order', c.presentation_order)
          order by c.presentation_order nulls last, m.name, m.team_id) as candidates
      from private.main_vote_tally() m join private.vote_candidates c on c.team_id = m.team_id
      where m.tied_count > 1 group by m.vote_count
    ) g;
  end if;
  if result->>'status' = 'published' or (actor.role in ('owner', 'staff') and result->>'status' = 'closed') then
    select coalesce(jsonb_agg(private.get_runoff(id) order by opens_at, id), '[]') into history
      from private.vote_runoffs where closed_at is not null;
    select coalesce(jsonb_agg(value || jsonb_build_object('main_rank', m.raw_rank, 'main_tied_count', m.tied_count,
      'runoff_vote_count', rt.vote_count) order by (value->>'raw_rank')::integer, value->>'name', value->>'team_id'), '[]')
      into results from jsonb_array_elements(result->'results') j
      join private.main_vote_tally() m on m.team_id = (value->>'team_id')::uuid
      left join private.vote_runoffs vr on vr.main_vote_count = m.vote_count and vr.closed_at is not null
      left join lateral private.runoff_tally(vr.id) rt on rt.team_id = m.team_id;
  end if;
  return result || jsonb_build_object('runoff', runoff, 'runoff_groups', groups, 'runoff_history', history, 'results', results);
end;
$$;

-- The original publish validator reads vote_tally, which now includes closed runoffs.
alter function private.manage_vote(text, uuid[], jsonb) rename to manage_main_vote;
create function private.manage_vote(p_action text, p_candidate_ids uuid[], p_awards jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare actor public.members := private.current_member();
begin
  if actor.id is null or actor.role <> 'owner' then
    raise exception '총관리자 권한이 필요합니다.' using errcode = '42501';
  end if;
  perform 1 from public.event_settings where id for update;
  actor := private.current_member();
  if actor.id is null or actor.role <> 'owner' then
    raise exception '총관리자 권한이 필요합니다.' using errcode = '42501';
  end if;
  if p_action = 'publish' and exists (select 1 from private.vote_runoffs where closed_at is null) then
    raise exception '진행 중인 재투표의 마감을 먼저 확정해 주세요.' using errcode = '22023';
  end if;
  perform private.manage_main_vote(p_action, p_candidate_ids, p_awards);
end;
$$;

-- Refresh public SQL function plans after replacing the renamed private targets.
create or replace function public.get_vote_overview() returns jsonb
language sql volatile security invoker set search_path = '' as $$ select private.get_vote_overview() $$;
create or replace function public.get_vote_details() returns jsonb
language sql volatile security invoker set search_path = '' as $$ select private.get_vote_details() $$;
create or replace function public.manage_vote(p_action text, p_candidate_ids uuid[] default null, p_awards jsonb default null) returns void
language sql security invoker set search_path = '' as $$ select private.manage_vote(p_action, p_candidate_ids, p_awards) $$;

create function public.manage_runoff(p_action text, p_candidate_ids uuid[] default null, p_closes_at timestamptz default null, p_runoff_id uuid default null)
returns void language sql security invoker set search_path = '' as $$ select private.manage_runoff(p_action, p_candidate_ids, p_closes_at, p_runoff_id) $$;
create function public.cast_runoff_vote(p_runoff_id uuid, p_team_id uuid) returns void
language sql security invoker set search_path = '' as $$ select private.cast_runoff_vote(p_runoff_id, p_team_id) $$;

revoke all on function private.main_vote_tally(), private.vote_tally(), private.runoff_tally(uuid), private.get_runoff(uuid),
  private.get_main_vote_overview(), private.get_main_vote_details(), private.manage_main_vote(text, uuid[], jsonb),
  private.get_vote_overview(), private.get_vote_details(), private.manage_vote(text, uuid[], jsonb),
  private.manage_runoff(text, uuid[], timestamptz, uuid), private.cast_runoff_vote(uuid, uuid),
  public.manage_runoff(text, uuid[], timestamptz, uuid), public.cast_runoff_vote(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function private.get_vote_overview(), private.get_vote_details(), private.manage_vote(text, uuid[], jsonb),
  private.manage_runoff(text, uuid[], timestamptz, uuid), private.cast_runoff_vote(uuid, uuid),
  public.manage_runoff(text, uuid[], timestamptz, uuid), public.cast_runoff_vote(uuid, uuid) to authenticated;
