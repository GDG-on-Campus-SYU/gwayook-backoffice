alter table public.event_settings
  add column vote_status text not null default 'draft' check (vote_status in ('draft', 'open', 'closed', 'published')),
  add column vote_closed_at timestamptz,
  add column vote_published_at timestamptz;

create table private.vote_candidates (
  team_id uuid primary key references public.teams (id),
  name text not null,
  presentation_order integer
);

create table private.vote_eligibility (
  member_id uuid primary key references public.members (id),
  team_id uuid not null references public.teams (id),
  unique (member_id, team_id)
);

create table private.votes (
  member_id uuid primary key,
  own_team_id uuid not null,
  team_id uuid not null references private.vote_candidates (team_id),
  updated_at timestamptz not null default clock_timestamp(),
  foreign key (member_id, own_team_id) references private.vote_eligibility (member_id, team_id),
  check (own_team_id <> team_id)
);

create table private.award_decisions (
  final_rank integer primary key check (final_rank > 0),
  team_id uuid not null unique references private.vote_candidates (team_id),
  award_name text not null check (char_length(award_name) between 1 and 80),
  tie_reason text check (char_length(tie_reason) between 1 and 500),
  decided_by uuid not null references public.members (id),
  decided_at timestamptz not null default clock_timestamp()
);

alter table private.vote_candidates enable row level security;
alter table private.vote_eligibility enable row level security;
alter table private.votes enable row level security;
alter table private.award_decisions enable row level security;
revoke all on private.vote_candidates, private.vote_eligibility, private.votes, private.award_decisions
  from public, anon, authenticated, service_role;

create function private.vote_tally()
returns table (team_id uuid, name text, vote_count integer, raw_rank integer, tied_count integer)
language sql stable set search_path = '' as $$
  with counts as (
    select c.team_id, c.name, count(v.member_id)::integer as vote_count
    from private.vote_candidates c left join private.votes v on c.team_id = v.team_id
    group by c.team_id, c.name
  )
  select c.team_id, c.name, c.vote_count,
    rank() over (order by c.vote_count desc)::integer,
    count(*) over (partition by c.vote_count)::integer
  from counts c;
$$;

create function private.get_vote_overview() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  event public.event_settings;
  eligible_count integer;
  voted_count integer;
begin
  if actor.id is null then
    raise exception '행사 명단에 등록된 계정이 필요합니다.' using errcode = '42501';
  end if;
  select * into strict event from public.event_settings where id;
  if actor.role in ('owner', 'staff') then
    if event.vote_status = 'draft' then
      select count(*) into eligible_count from public.members where active and role = 'participant' and team_id is not null;
      voted_count := 0;
    else
      select count(*) into eligible_count from private.vote_eligibility;
      select count(*) into voted_count from private.votes;
    end if;
  end if;
  return jsonb_build_object(
    'status', case when event.vote_status = 'open' and event.vote_closes_at <= statement_timestamp() then 'expired' else event.vote_status end,
    'closes_at', least(event.vote_closes_at, event.vote_closed_at),
    'eligible', actor.role = 'participant' and exists (select 1 from private.vote_eligibility where member_id = actor.id),
    'voted', actor.role = 'participant' and exists (select 1 from private.votes where member_id = actor.id),
    'eligible_count', eligible_count, 'voted_count', voted_count
  );
end;
$$;

create function private.get_vote_details() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  overview jsonb := private.get_vote_overview();
  status text := overview->>'status';
  candidates jsonb := '[]';
  results jsonb := '[]';
  own_team_id uuid;
  choice_id uuid;
begin
  if status = 'draft' and actor.role in ('owner', 'staff') then
    select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'presentation_order', t.presentation_order,
      'active_member_count', (select count(*) from public.members m where m.team_id = t.id and m.role = 'participant' and m.active))
      order by t.presentation_order nulls last, t.name, t.id), '[]'::jsonb) into candidates from public.teams t;
  elsif status <> 'draft' then
    select coalesce(jsonb_agg(jsonb_build_object('id', c.team_id, 'name', c.name, 'presentation_order', c.presentation_order)
      order by c.presentation_order nulls last, c.name, c.team_id), '[]'::jsonb) into candidates from private.vote_candidates c;
  end if;

  if status = 'open' and actor.role = 'participant' then
    select e.team_id, v.team_id into own_team_id, choice_id from private.vote_eligibility e
    left join private.votes v on e.member_id = v.member_id where e.member_id = actor.id;
  end if;

  if status = 'published' or (status = 'closed' and actor.role in ('owner', 'staff')) then
    select coalesce(jsonb_agg(to_jsonb(t) || jsonb_build_object('final_rank', a.final_rank, 'award_name', a.award_name,
      'tie_reason', case when actor.role in ('owner', 'staff') then a.tie_reason end)
      order by t.raw_rank, t.name, t.team_id), '[]'::jsonb) into results
    from private.vote_tally() t left join private.award_decisions a on t.team_id = a.team_id;
  end if;
  return overview || jsonb_build_object('candidates', candidates, 'own_team_id', own_team_id, 'choice_id', choice_id, 'results', results);
end;
$$;

create function private.cast_vote(p_team_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  event public.event_settings;
  own_team_id uuid;
begin
  if actor.id is null or actor.role <> 'participant' then
    raise exception '참가자에게만 투표권이 있습니다.' using errcode = '42501';
  end if;
  -- Roster edits, vote changes, and closing share the same transaction lock.
  select * into strict event from public.event_settings where id for update;
  actor := private.current_member();
  if actor.id is null or actor.role <> 'participant' then
    raise exception '참가자에게만 투표권이 있습니다.' using errcode = '42501';
  end if;
  if event.vote_status <> 'open' or event.vote_closes_at <= clock_timestamp() then
    raise exception '지금은 투표할 수 없습니다.' using errcode = '22023';
  end if;
  select team_id into own_team_id from private.vote_eligibility where member_id = actor.id;
  if not found then raise exception '이번 투표의 유권자 명단에 없습니다.' using errcode = '42501'; end if;
  if own_team_id = p_team_id then raise exception '자기 팀에는 투표할 수 없습니다.' using errcode = '22023'; end if;
  if not exists (select 1 from private.vote_candidates where team_id = p_team_id) then
    raise exception '투표 후보 팀을 다시 선택해 주세요.' using errcode = '22023';
  end if;

  insert into private.votes (member_id, own_team_id, team_id) values (actor.id, own_team_id, p_team_id)
  on conflict (member_id) do update set team_id = excluded.team_id, updated_at = clock_timestamp()
    where votes.team_id is distinct from excluded.team_id;
end;
$$;

create function private.manage_vote(p_action text, p_candidate_ids uuid[], p_awards jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  event public.event_settings;
  action_at timestamptz;
  award jsonb;
  ranking integer := 0;
  team uuid;
  label text;
  reason text;
  tally record;
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

  case p_action
    when 'open' then
      if event.vote_status <> 'draft' then raise exception '준비 상태에서만 투표를 열 수 있습니다.' using errcode = '22023'; end if;
      if event.vote_closes_at is null or event.vote_closes_at <= action_at then
        raise exception '설정에서 현재 시각 이후의 투표 마감을 지정해 주세요.' using errcode = '22023';
      end if;
      if coalesce(cardinality(p_candidate_ids), 0) not between 2 and 200 or
        (select count(*) from public.teams where id = any(p_candidate_ids)) <> cardinality(p_candidate_ids) then
        raise exception '서로 다른 후보 팀을 2개 이상 선택해 주세요.' using errcode = '22023';
      end if;
      insert into private.vote_candidates (team_id, name, presentation_order)
        select id, name, presentation_order from public.teams where id = any(p_candidate_ids);
      insert into private.vote_eligibility (member_id, team_id)
        select id, team_id from public.members where role = 'participant' and active and team_id is not null;
      if not found then raise exception '팀이 배정된 활성 참가자가 필요합니다.' using errcode = '22023'; end if;
      update public.event_settings set vote_status = 'open', vote_opens_at = action_at where id;
    when 'close' then
      if event.vote_status <> 'open' then raise exception '진행 중인 투표만 마감할 수 있습니다.' using errcode = '22023'; end if;
      update public.event_settings set vote_status = 'closed', vote_closed_at = action_at where id;
    when 'publish' then
      if event.vote_status <> 'closed' then raise exception '마감한 투표만 공개할 수 있습니다.' using errcode = '22023'; end if;
      if jsonb_typeof(p_awards) is distinct from 'array' then raise exception '수상 정보를 확인해 주세요.' using errcode = '22023'; end if;
      if jsonb_array_length(p_awards) not between 1 and (select count(*) from private.vote_candidates) then
        raise exception '수상 팀 수는 1개 이상, 후보 팀 수 이하여야 합니다.' using errcode = '22023';
      end if;
      for award in select value from jsonb_array_elements(p_awards) loop
        ranking := ranking + 1;
        team := (award->>'team_id')::uuid;
        label := btrim(award->>'award_name');
        reason := nullif(btrim(award->>'tie_reason'), '');
        if jsonb_typeof(award->'award_name') is distinct from 'string' or char_length(label) not between 1 and 80
          or coalesce(jsonb_typeof(award->'tie_reason'), 'null') not in ('null', 'string') or char_length(reason) > 500 then
          raise exception '수상명이나 동점 결정 사유를 확인해 주세요.' using errcode = '22023';
        end if;
        select * into tally from private.vote_tally() where team_id = team;
        if not found or ranking < tally.raw_rank or ranking >= tally.raw_rank + tally.tied_count then
          raise exception '수상 순위는 득표순을 따릅니다. 동점 팀 안에서만 순서를 정해 주세요.' using errcode = '22023';
        end if;
        if tally.tied_count > 1 and reason is null then
          raise exception '동점인 팀의 수상 순위를 정한 사유를 입력해 주세요.' using errcode = '22023';
        end if;
        insert into private.award_decisions (final_rank, team_id, award_name, tie_reason, decided_by)
          values (ranking, team, label, case when tally.tied_count > 1 then reason end, actor.id);
      end loop;
      update public.event_settings set vote_status = 'published', vote_published_at = action_at where id;
    else
      raise exception '투표 작업을 다시 선택해 주세요.' using errcode = '22023';
  end case;

  insert into public.audit_logs (actor_id, action, details) values (actor.id, 'vote_' || p_action,
    case p_action when 'open' then jsonb_build_object('candidate_count', cardinality(p_candidate_ids))
      when 'publish' then jsonb_build_object('award_count', ranking) else '{}'::jsonb end);
exception
  when unique_violation then raise exception '같은 팀을 여러 수상 순위에 지정할 수 없습니다.' using errcode = '22023';
  when invalid_text_representation then raise exception '선택한 팀을 다시 확인해 주세요.' using errcode = '22023';
end;
$$;

create function public.get_vote_overview() returns jsonb
language sql stable security invoker set search_path = '' as $$ select private.get_vote_overview() $$;
create function public.get_vote_details() returns jsonb
language sql stable security invoker set search_path = '' as $$ select private.get_vote_details() $$;
create function public.cast_vote(p_team_id uuid) returns void
language sql security invoker set search_path = '' as $$ select private.cast_vote(p_team_id) $$;
create function public.manage_vote(p_action text, p_candidate_ids uuid[] default null, p_awards jsonb default null) returns void
language sql security invoker set search_path = '' as $$ select private.manage_vote(p_action, p_candidate_ids, p_awards) $$;

revoke all on function private.vote_tally(), private.get_vote_overview(), private.get_vote_details(), private.cast_vote(uuid),
  private.manage_vote(text, uuid[], jsonb), public.get_vote_overview(), public.get_vote_details(), public.cast_vote(uuid),
  public.manage_vote(text, uuid[], jsonb) from public, anon, authenticated, service_role;
grant execute on function private.get_vote_overview(), private.get_vote_details(), private.cast_vote(uuid),
  private.manage_vote(text, uuid[], jsonb), public.get_vote_overview(), public.get_vote_details(), public.cast_vote(uuid),
  public.manage_vote(text, uuid[], jsonb) to authenticated;
