-- Add readiness summaries to existing private scenarios. No game data changes.
begin;
-- Count filled tasks, not just the slots in the game field. Private helper: no answers in summaries.
create or replace function public.mg_task_status(rows jsonb)returns jsonb language sql immutable set search_path=''as $$
with slots as(select x->>'code'code,nullif(trim(x->'content'->>'condition'),'')is not null filled,(x->'content'->>'kind'='cutting'or x->'content'->>'mode'='manual'or nullif(trim(x->'content'->>'key'),'')is not null)has_key from jsonb_array_elements(coalesce(rows,'[]'))x)
select jsonb_build_object('total',count(*),'filled',count(*)filter(where filled),'ready',count(*)filter(where filled and has_key),'missing',coalesce(jsonb_agg(jsonb_build_object('code',code,'reason',case when not filled then 'Нет условия'else 'Нет ключа проверки'end))filter(where not filled or not coalesce(has_key,false)),'[]'))from slots $$;
revoke all on function public.mg_task_status(jsonb)from public,anon,authenticated;
create or replace function public.mg_templates(op text,payload jsonb default '{}')returns jsonb language plpgsql security definer set search_path=''as $$
#variable_conflict use_column
declare u uuid:=auth.uid();tmpl public.mg_game_templates;run public.mg_template_runs;tid uuid:=(payload->>'id')::uuid;gid uuid;host text;k text;v_title text;v_settings jsonb;rows jsonb;created jsonb;s jsonb;names jsonb;req uuid;begin
if u is null then raise exception 'Войдите в личные сценарии игр';end if;
if op='list'then return coalesce((select jsonb_agg(to_jsonb(x))from(select id,title,game_kind,settings,updated_at,jsonb_array_length(tasks)task_count,public.mg_task_status(tasks)task_status from public.mg_game_templates where owner_id=u order by updated_at desc limit 100)x),'[]');end if;
if op='recent'then return coalesce((select jsonb_agg(to_jsonb(x))from(select game_kind,game_id,host_token,template_id,created_at from public.mg_template_runs where owner_id=u order by created_at desc limit 20)x),'[]');end if;
if tid is not null then select *into tmpl from public.mg_game_templates where id=tid and owner_id=u for update;if not found then raise exception 'Сценарий недоступен';end if;end if;
if op='get'then if tid is null then raise exception 'Выберите сценарий';end if;return(to_jsonb(tmpl)-'owner_id')||jsonb_build_object('task_status',public.mg_task_status(tmpl.tasks));end if;
if op='delete'then if tid is null then raise exception 'Выберите сценарий';end if;delete from public.mg_game_templates where id=tid;return '{}';end if;
if op='rename'then v_title:=trim(payload->>'title');if tid is null or v_title is null or length(v_title)not between 1 and 100 then raise exception 'Название: до 100 символов';end if;update public.mg_game_templates set title=v_title,updated_at=now()where id=tid;return jsonb_build_object('id',tid);end if;
if op='save'then
k:=payload->>'kind';gid:=(payload->>'game')::uuid;host:=payload->>'token';v_title:=trim(payload->>'title');
if not public.mg_host(k,gid,host)then raise exception 'Нужна ссылка ведущего';end if;if v_title is null or length(v_title)not between 1 and 100 then raise exception 'Название: до 100 символов';end if;
if exists(select 1 from public.mg_lifecycle where game_kind=k and game_id=gid and archived)then raise exception 'Подробности игры уже очищены. Сохраните сценарий до очистки задач';end if;
rows:=public.mg_tasks(k,gid,host,'get')->'rows';
case k when 'od'then select jsonb_build_object('title',g.title,'online',g.online,'names',coalesce((select jsonb_agg(name order by name)from public.od_teams where game_id=gid),'["Команда 1","Команда 2","Команда 3"]'))into v_settings from public.od_games g where id=gid;
when 'ab'then select jsonb_build_object('title',g.title,'online',g.online,'themes',g.themes,'tasks',g.tasks_per_theme,'minutes',g.minutes,'names',(select jsonb_agg(name order by position)from public.ab_teams where game_id=gid))into v_settings from public.ab_games g where id=gid;
when 'ps'then select jsonb_build_object('title',g.title,'online',g.online,'rounds',g.rounds,'interval',g.interval_min,'names',(select jsonb_agg(name order by position)from public.ps_teams where game_id=gid))into v_settings from public.ps_games g where id=gid;
else select jsonb_build_object('title',w.title)into v_settings from public.mg_workbenches w where id=gid;end case;
if tid is null then insert into public.mg_game_templates(owner_id,title,game_kind,settings,tasks)values(u,v_title,k,v_settings,rows)returning id into tid;else update public.mg_game_templates set title=v_title,game_kind=k,settings=v_settings,tasks=rows,updated_at=now()where id=tid;end if;return jsonb_build_object('id',tid,'task_status',public.mg_task_status(rows));
end if;
if op='launch'then
if tid is null then raise exception 'Выберите сценарий';end if;req:=(payload->>'request')::uuid;if req is null then raise exception 'Нужен идентификатор запуска';end if;
-- Serialize double-click/retry for this owner+request. Completed response is privately recoverable.
perform pg_advisory_xact_lock(hashtextextended(u::text||req::text,0));select *into run from public.mg_template_runs where owner_id=u and request_id=req;if found then return jsonb_build_object('id',run.game_id,'hostToken',run.host_token,'kind',run.game_kind,'template_id',run.template_id);end if;
k:=tmpl.game_kind;v_settings:=tmpl.settings;v_title:=left(coalesce(nullif(trim(payload->>'title'),''),tmpl.title),100);
case k when 'od'then created:=public.od_api('create',null,'',jsonb_build_object('title',v_title));gid:=(created->>'game')::uuid;host:=created->>'host';perform public.od_api('configure',gid,host,jsonb_build_object('names',v_settings->'names'));perform public.od_api('delivery',gid,host,jsonb_build_object('online',v_settings->'online'));
when 'ab'then created:=public.ab_api('create',null,'',jsonb_build_object('title',v_title));gid:=(created->>'id')::uuid;host:=created->>'hostToken';perform public.ab_api('configure',gid,host,v_settings);perform public.ab_api('delivery',gid,host,jsonb_build_object('online',v_settings->'online'));
when 'ps'then created:=public.ps_api('create',null,'',jsonb_build_object('title',v_title));gid:=(created->>'id')::uuid;host:=created->>'hostToken';perform public.ps_api('configure',gid,host,v_settings);perform public.ps_api('delivery',gid,host,jsonb_build_object('online',v_settings->'online'));
else created:=public.mg_tasks('birzha',null,'','create');gid:=(created->>'id')::uuid;host:=created->>'hostToken';update public.mg_workbenches set title=v_title where id=gid;end case;
select coalesce(jsonb_agg(x-'bank_id'-'bank_version'),'[]')into rows from jsonb_array_elements(tmpl.tasks)x;perform public.mg_tasks(k,gid,host,'save',jsonb_build_object('rows',rows));
insert into public.mg_template_runs(owner_id,request_id,template_id,game_kind,game_id,host_token)values(u,req,tid,k,gid,host);return jsonb_build_object('id',gid,'hostToken',host,'kind',k,'template_id',tid);
end if;raise exception 'Неизвестное действие';end $$;
revoke all on function public.mg_templates(text,jsonb)from public,anon;
grant execute on function public.mg_templates(text,jsonb)to authenticated;
commit;
