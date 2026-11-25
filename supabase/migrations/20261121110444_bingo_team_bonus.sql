create table private.bingo_team_bonus (
  team_id uuid primary key references public.teams(id) on delete cascade,
  points smallint not null check (points > 0)
);
alter table private.bingo_team_bonus enable row level security;
revoke all on private.bingo_team_bonus from public, anon, authenticated, service_role;

create function private.get_bingo_bonuses() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_staff();
  return jsonb_build_object(
    'locked', exists(select 1 from private.vote_runoffs)
      or exists(select 1 from public.event_settings where id and vote_status = 'published'),
    'teams', (select coalesce(jsonb_agg(jsonb_build_object(
        'team_id', t.id, 'name', t.name, 'bingo_bonus', coalesce(b.points, 0))
        order by t.presentation_order nulls last, t.name, t.id), '[]'::jsonb)
      from public.teams t left join private.bingo_team_bonus b on b.team_id = t.id)
  );
end;
$$;

create function private.set_bingo_bonus(p_team_id uuid, p_points integer, p_expected_points integer)
returns void language plpgsql security definer set search_path = '' as $$
declare
  actor uuid;
  published boolean;
  previous_points integer;
begin
  perform private.require_staff();
  select vote_status = 'published' into strict published from public.event_settings where id for update;
  actor := private.require_staff();
  if published or exists(select 1 from private.vote_runoffs) then
    raise exception '첫 재투표를 시작했거나 결과를 공개한 뒤에는 가산점을 변경할 수 없습니다.' using errcode = '22023';
  end if;
  if p_points is null or p_points not between 0 and 32767
    or p_expected_points is null or p_expected_points not between 0 and 32767 then
    raise exception '빙고 가산점은 0~32767 사이의 정수로 입력해 주세요.' using errcode = '22023';
  end if;
  select coalesce(b.points, 0) into previous_points
    from public.teams t left join private.bingo_team_bonus b on b.team_id = t.id where t.id = p_team_id;
  if not found then
    raise exception '가산점을 설정할 팀을 확인해 주세요.' using errcode = '22023';
  end if;
  if p_points = previous_points then return; end if;
  if p_expected_points <> previous_points then
    raise exception '다른 운영진이 빙고 가산점을 변경했습니다. 현재 점수를 확인해 주세요.' using errcode = '40001';
  end if;
  if p_points = 0 then
    delete from private.bingo_team_bonus where team_id = p_team_id;
  else
    insert into private.bingo_team_bonus(team_id, points) values(p_team_id, p_points)
      on conflict(team_id) do update set points = excluded.points;
  end if;
  insert into public.audit_logs(actor_id, action, target_id, details)
    values(actor, 'bingo_bonus_changed', p_team_id, jsonb_build_object('before', previous_points, 'after', p_points));
end;
$$;

create function public.get_bingo_bonuses() returns jsonb
language sql stable security invoker set search_path = '' as $$ select private.get_bingo_bonuses(); $$;
create function public.set_bingo_bonus(p_team_id uuid, p_points integer, p_expected_points integer)
returns void language sql security invoker set search_path = '' as $$
  select private.set_bingo_bonus(p_team_id, p_points, p_expected_points);
$$;
revoke all on function private.get_bingo_bonuses(), public.get_bingo_bonuses(),
  private.set_bingo_bonus(uuid,integer,integer), public.set_bingo_bonus(uuid,integer,integer)
  from public, anon, authenticated, service_role;
grant execute on function private.get_bingo_bonuses(), public.get_bingo_bonuses(),
  private.set_bingo_bonus(uuid,integer,integer), public.set_bingo_bonus(uuid,integer,integer) to authenticated;

-- PostgreSQL requires recreating this private function to extend its row type.
drop function private.main_score_tally();
create function private.main_score_tally()
returns table(team_id uuid, name text, vote_count integer, gemini_bonus integer, total_score integer,
  raw_rank integer, tied_count integer, bingo_bonus integer)
language sql stable set search_path = '' as $$
  with components as (
    select m.team_id, m.name, m.vote_count, case when g.gemini_qualified then 1 else 0 end as gemini_bonus,
      coalesce(b.points, 0)::integer as bingo_bonus
    from private.main_vote_tally() m
    left join private.team_bonus g on g.team_id = m.team_id
    left join private.bingo_team_bonus b on b.team_id = m.team_id
  ), scores as (
    select c.*, c.vote_count + c.gemini_bonus + c.bingo_bonus as total_score from components c
  )
  select s.team_id, s.name, s.vote_count, s.gemini_bonus, s.total_score,
    rank() over(order by s.total_score desc)::integer,
    count(*) over(partition by s.total_score)::integer, s.bingo_bonus
  from scores s;
$$;
revoke all on function private.main_score_tally() from public, anon, authenticated, service_role;

-- Keep the existing result visibility checks, access-log wrappers, and CSV column positions.
do $migration$
declare patch record; definition text;
begin
  for patch in select * from (values
    ('private.get_vote_details_without_access_log()',
      $old$'gemini_bonus',m.gemini_bonus,$old$,
      $new$'gemini_bonus',m.gemini_bonus,'bingo_bonus',m.bingo_bonus,$new$),
    ('private.manage_runoff(text,uuid[],timestamptz,uuid)',
      '본투표 원득표와 Gemini 가산점 합계가 같은', '본투표 원득표와 가산점 합계가 같은'),
    ('private.get_event_export_without_access_log(text)',
      '"동점 팀 수","결과 상태"]', '"동점 팀 수","결과 상태","빙고 가산점"]'),
    ('private.get_event_export_without_access_log(text)',
      $old$else '마감 · 미공개' end) order by n$old$,
      $new$else '마감 · 미공개' end,(p->>'bingo_bonus')::integer) order by n$new$),
    ('private.get_event_export_without_access_log(text)',
      '"마감된 재투표 득표","동점 결정 사유"]', '"마감된 재투표 득표","동점 결정 사유","빙고 가산점"]'),
    ('private.get_event_export_without_access_log(text)',
      $old$p->>'tie_reason') order by (p->>'final_rank')$old$,
      $new$p->>'tie_reason',(p->>'bingo_bonus')::integer) order by (p->>'final_rank')$new$)
  ) patches(signature, old, new) loop
    definition := pg_get_functiondef(patch.signature::regprocedure);
    if (length(definition)-length(replace(definition,patch.old,'')))/length(patch.old) <> 1 then
      raise exception 'Expected exactly one match in %: %', patch.signature, patch.old;
    end if;
    execute replace(definition, patch.old, patch.new);
  end loop;
end;
$migration$;
