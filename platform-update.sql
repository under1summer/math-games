-- Run ONCE for existing installations from 25 November 2026. Data preserved.
begin;
alter table public.ps_games add column online boolean not null default true;
alter table public.ps_tasks add column mode text not null default 'manual' check(mode in ('number','set','text','manual')),add column key text not null default '';
create table public.ps_submissions (
 id uuid primary key,game_id uuid not null references public.ps_games(id),team_id uuid not null references public.ps_teams(id),
 task_code text not null,target_id uuid references public.ps_teams(id),answer text not null check(length(answer) between 1 and 6000),
 time_ms bigint not null,status text not null default 'PENDING' check(status in ('PENDING','JUDGED','CANCELLED')),
 correct boolean,review_source text,event_id bigint references public.ps_events(id),note text not null default '',
 foreign key(game_id,task_code) references public.ps_tasks(game_id,code)
);
create unique index ps_one_submission on public.ps_submissions(game_id,team_id,task_code) where status<>'CANCELLED';
alter table public.ps_submissions enable row level security;
revoke all on public.ps_submissions from anon,authenticated;

create function public.ps_normal(s text, mode text) returns text language plpgsql immutable set search_path='' as $$
declare x text; a text[]; item text; r text[] := '{}';
begin
 x:=lower(replace(replace(replace(trim(s),'ё','е'),'−','-'),'–','-'));
 x:=regexp_replace(x,'^(ответы?|числа|число)\s*:?\s*','','i');
 x:=regexp_replace(x,'[()\[\]{}]','','g');
 if mode='text' then return regexp_replace(x,'[\s,;:.→>\-]+','','g'); end if;
 x:=regexp_replace(x,'(минут[а-я]*|мин\.?|секунд[а-я]*|сек\.?|часа?|часов|человек[а-я]*|девоч[а-я]*|ученик[а-я]*|школьник[а-я]*|животн[а-я]*|треугольник[а-я]*|плит[а-я]*|гном[а-я]*)','','g');
 x:=regexp_replace(x,'[xхnаa]\s*=\s*','','g'); x:=trim(x);
 if mode='number' then
  if x ~ '^[+-]?[0-9]{1,3}([   ][0-9]{3})+([.,][0-9]+)?$' then x:=regexp_replace(x,'[   ]','','g'); end if;
  x:=replace(x,',','.');
  if x !~ '^[+-]?[0-9]+(\.[0-9]+)?$' or length(x)>100 then return null; end if;
  return trim_scale(x::numeric)::text;
 end if;
 x:=regexp_replace(x,'либо|или|и',';','g'); x:=regexp_replace(trim(x),'[.;]+$','');
 if x !~ '^[+-]?[0-9]+([\s,;|*×хx·]+[+-]?[0-9]+)*$' or length(x)>1000 then return null; end if;
 a:=regexp_split_to_array(x,'[\s,;|*×хx·]+');
 foreach item in array a loop
  if length(item)>100 then return null; end if;
  r:=array_append(r,trim_scale(item::numeric)::text);
 end loop;
 return (select string_agg(v,';' order by v) from unnest(r) v);
end $$;

create function public.ps_decide(sid uuid, verdict boolean, source text) returns void language plpgsql set search_path='' as $$
declare q public.ps_submissions;e public.ps_events;t public.ps_tasks;eid bigint;stamp bigint:=floor(extract(epoch from clock_timestamp())*1000);roll_value numeric;
begin
 select * into q from public.ps_submissions where id=sid for update;
 if not found or q.status='CANCELLED' then raise exception 'Сдача не найдена или отменена';end if;
 select * into t from public.ps_tasks where game_id=q.game_id and code=q.task_code;
 if q.event_id is null then
  insert into public.ps_events(request_id,game_id,time_ms,kind,data) values(q.id,q.game_id,stamp,'answer',jsonb_build_object('team',q.team_id,'task',q.task_code,'target',q.target_id,'correct',verdict,'submission',q.id,'roll',case when verdict and t.task_type='shot' then random() else null end)) returning id into eid;
 else
  eid:=q.event_id;select * into e from public.ps_events where id=eid;
  roll_value:=(e.data->>'roll')::numeric;
  if verdict and t.task_type='shot' and roll_value is null then roll_value:=random();end if;
  update public.ps_events set data=data||jsonb_build_object('correct',verdict,'roll',roll_value) where id=eid;
  if q.correct is distinct from verdict then
   insert into public.ps_events(request_id,game_id,time_ms,kind,data) values(gen_random_uuid(),q.game_id,stamp,'review',jsonb_build_object('submission',q.id,'event',eid,'before',q.correct,'after',verdict));
  end if;
 end if;
 update public.ps_submissions set status='JUDGED',correct=verdict,event_id=eid,review_source=source where id=q.id;
end $$;

create or replace function public.ps_api(op text,game uuid default null,token text default '',payload jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare g public.ps_games;tm public.ps_teams;task public.ps_tasks;ev public.ps_events;sub public.ps_submissions;host boolean:=false;now_ms bigint:=floor(extract(epoch from clock_timestamp())*1000);
 secret text;gid uuid;clock jsonb;result jsonb;names jsonb;rounds_new int;interval_new int;issued int;i int;req uuid;actor_id uuid;target_id uuid;reason text;delta numeric;correct boolean;val text;e_id bigint;task_list jsonb;j jsonb;norm text;st text;
begin
 if op='create' then
  secret:=gen_random_uuid()::text||gen_random_uuid()::text;
  insert into public.ps_games(host_hash,title) values(sha256(convert_to(secret,'UTF8')),left(coalesce(nullif(trim(payload->>'title'),''),'Перестрелка'),100)) returning * into g;
  insert into public.ps_teams(game_id,position,name,token) select g.id,nn.n,'Команда '||nn.n,gen_random_uuid()::text||gen_random_uuid()::text from generate_series(1,4) nn(n);
  perform public.ps_seed(g.id,g.rounds);return jsonb_build_object('id',g.id,'hostToken',secret);
 end if;
 select * into g from public.ps_games where id=game;
 if not found then raise exception 'Игра не найдена'; end if;
 host:=length(token)>0 and sha256(convert_to(token,'UTF8'))=g.host_hash;
 if not host and token<>'' then select * into tm from public.ps_teams t where t.game_id=g.id and t.token=ps_api.token;if not found then raise exception 'Неверная ссылка команды';end if;end if;
 if op is null or op not in ('state','configure','start','pause','resume','finish','rounds','issue','answer','hp','cancel','undo','new','export','submit','judge','cancelSubmission','tasks','delivery') then raise exception 'Неизвестное действие';end if;
 if op not in ('state','submit') and not host then raise exception 'Действие доступно только ведущему';end if;
 if op<>'state' then select * into g from public.ps_games where id=g.id for update;end if;
 clock:=public.ps_clock(g,now_ms);issued:=(clock->>'issued')::int;
 if op='delivery' then
  if g.status<>'READY' or jsonb_typeof(payload->'online') is distinct from 'boolean' then raise exception 'Режим выбирается до старта';end if;
  update public.ps_games set online=(payload->>'online')::boolean where id=g.id;
 elsif op='submit' then
  if host and not g.online then select * into tm from public.ps_teams where id=(payload->>'team')::uuid and game_id=g.id;
  elsif not g.online then raise exception 'Игра в аудитории: сдайте ответ на листочке ведущему';end if;
  if tm.id is null then raise exception 'Используйте личную ссылку команды';end if;
  req:=(payload->>'id')::uuid;if req is null then raise exception 'Нужен ID запроса';end if;
  select * into sub from public.ps_submissions where id=req;
  if found then
   if sub.game_id<>g.id or sub.team_id<>tm.id then raise exception 'ID уже занят';end if;
   return public.ps_api('state',g.id,token);
  end if;
  if clock->>'status'<>'RUNNING' then raise exception 'Приём ответов закрыт или приостановлен';end if;
  select * into task from public.ps_tasks where game_id=g.id and code=payload->>'task';
  if not found or (task.task_type='shot' and task.round_no>issued) then raise exception 'Задача ещё не выдана';end if;
  if task.kind<>'standard' or task.module_id is not null then raise exception 'Интерактивный модуль пока не подключён';end if;
  if exists(select 1 from public.ps_events where game_id=g.id and kind='answer' and not cancelled and data->>'team'=tm.id::text and data->>'task'=task.code)
   or exists(select 1 from public.ps_submissions where game_id=g.id and team_id=tm.id and task_code=task.code and status<>'CANCELLED') then raise exception 'Команда уже отправляла ответ на эту задачу';end if;
  val:=trim(coalesce(payload->>'answer',''));if length(val) not between 1 and 6000 then raise exception 'Введите ответ: до 6000 символов';end if;
  target_id:=null;
  if task.task_type='shot' then
   target_id:=(payload->>'target')::uuid;
   if target_id is null or target_id=tm.id or not exists(select 1 from public.ps_teams where id=target_id and game_id=g.id) then raise exception 'Выберите соперника';end if;
  end if;
  insert into public.ps_submissions(id,game_id,team_id,task_code,target_id,answer,time_ms) values(req,g.id,tm.id,task.code,target_id,val,now_ms);
  if task.mode<>'manual' then
   norm:=public.ps_normal(val,task.mode);
   if norm is not null then
    if exists(select 1 from unnest(string_to_array(task.key,'|')) k where public.ps_normal(k,task.mode)=norm) then perform public.ps_decide(req,true,'auto');
    elsif task.mode<>'text' then perform public.ps_decide(req,false,'auto');end if;
   end if;
  end if;
 elsif op='judge' then
  select * into sub from public.ps_submissions where id=(payload->>'submission')::uuid and game_id=g.id for update;
  if not found or sub.status='CANCELLED' then raise exception 'Сдача не найдена или отменена';end if;
  if jsonb_typeof(payload->'correct') is distinct from 'boolean' then raise exception 'Укажите вердикт';end if;
  perform public.ps_decide(sub.id,(payload->>'correct')::boolean,'manual');
 elsif op='tasks' then
  if g.status<>'READY' then raise exception 'Условия и ключи фиксируются после старта';end if;
  task_list:=payload->'tasks';
  if coalesce(jsonb_typeof(task_list),'')<>'array' or jsonb_array_length(task_list)<>g.rounds*6+20 then raise exception 'Заполните все задачи и аптечки';end if;
  if (select count(distinct x->>'code') from jsonb_array_elements(task_list) x)<>jsonb_array_length(task_list) then raise exception 'Повторяются задачи';end if;
  for j in select * from jsonb_array_elements(task_list) loop
   select * into task from public.ps_tasks where game_id=g.id and code=j->>'code' and (task_type='med' or round_no<=g.rounds);
   if not found or length(coalesce(j->>'statement',''))>20000 or coalesce(j->>'mode','') not in ('number','text','set','manual') or length(coalesce(j->>'key',''))>2000 then raise exception 'Неверные данные задачи';end if;
   if j->>'mode'<>'manual' then
    if nullif(trim(j->>'key'),'') is null then raise exception 'Укажите ключ для автопроверки';end if;
    for val in select unnest(string_to_array(j->>'key','|')) loop
     if nullif(trim(val),'') is null or public.ps_normal(val,j->>'mode') is null then raise exception 'Некорректный ключ';end if;
    end loop;
   end if;
   update public.ps_tasks set statement=coalesce(j->>'statement',''),mode=j->>'mode',key=coalesce(j->>'key','') where game_id=g.id and code=task.code;
  end loop;
 elsif op='cancelSubmission' then
  select * into sub from public.ps_submissions where id=(payload->>'submission')::uuid and game_id=g.id for update;
  if not found then raise exception 'Сдача не найдена';end if;
  if sub.status='CANCELLED' then return public.ps_api('state',g.id,token);end if;
  if sub.status='JUDGED' then raise exception 'Отмените проверенный ответ в журнале';end if;
  reason:=trim(coalesce(payload->>'reason',''));if length(reason) not between 1 and 500 then raise exception 'Укажите причину';end if;
  update public.ps_submissions set status='CANCELLED',note=reason where id=sub.id;
 elsif op='configure' then
  if g.status<>'READY' then raise exception 'Команды и интервал меняются только до старта';end if;
  names:=payload->'names';rounds_new:=(payload->>'rounds')::int;interval_new:=(payload->>'interval')::int;
  if rounds_new is null or rounds_new not between 1 and 120 or interval_new is null or interval_new not between 1 and 120 then raise exception 'Обойм: 1–120, интервал: 1–120 минут';end if;
  if coalesce(jsonb_typeof(names),'null')<>'array' or jsonb_array_length(names) not between 2 and 16 then raise exception 'Нужно 2–16 команд';end if;
  if exists(select 1 from jsonb_array_elements_text(names) x where x is null or length(trim(x)) not between 1 and 45) or (select count(distinct trim(x)) from jsonb_array_elements_text(names) x)<>jsonb_array_length(names) then raise exception 'Нужны разные названия до 45 символов';end if;
  delete from public.ps_teams where game_id=g.id and position>jsonb_array_length(names);
  for i in 1..jsonb_array_length(names) loop
   insert into public.ps_teams(game_id,position,name,token) values(g.id,i,trim(names->>(i-1)),gen_random_uuid()::text||gen_random_uuid()::text) on conflict(game_id,position) do update set name=excluded.name;
  end loop;
  update public.ps_games set rounds=rounds_new,interval_min=interval_new where id=g.id;perform public.ps_seed(g.id,rounds_new);
 elsif op='start' then
  if g.status<>'READY' then raise exception 'Игра уже запускалась';end if;
  update public.ps_games set status='RUNNING',start_ms=now_ms,manual_rounds=1 where id=g.id;
 elsif op='pause' then
  if clock->>'status'<>'RUNNING' then raise exception 'Игра не идёт';end if;
  update public.ps_games set status='PAUSED',paused_at_ms=now_ms where id=g.id;
 elsif op='resume' then
  if g.status<>'PAUSED' then raise exception 'Игра не на паузе';end if;
  update public.ps_games set status='RUNNING',pause_total_ms=pause_total_ms+now_ms-paused_at_ms,paused_at_ms=null where id=g.id;
 elsif op='finish' then
  if clock->>'status' not in ('RUNNING','PAUSED') then raise exception 'Игра уже завершена или не начиналась';end if;
  update public.ps_games set status='FINISHED',finished_elapsed_ms=(clock->>'elapsed')::bigint where id=g.id;
 elsif op='rounds' then
  rounds_new:=(payload->>'rounds')::int;
  if clock->>'status' not in ('READY','RUNNING','PAUSED') or rounds_new is null or rounds_new not between greatest(1,issued) and 120 then raise exception 'Нельзя установить лимит меньше уже выданных обойм';end if;
  update public.ps_games set rounds=rounds_new where id=g.id;perform public.ps_seed(g.id,rounds_new);
 elsif op='issue' then
  if clock->>'status' not in ('RUNNING','PAUSED') or issued>=g.rounds then raise exception 'Следующая обойма недоступна';end if;
  update public.ps_games set manual_rounds=issued+1 where id=g.id;
 elsif op in ('answer','hp') then
  req:=(payload->>'id')::uuid;if req is null then raise exception 'Нужен ID запроса';end if;
  select * into ev from public.ps_events where request_id=req;
  if found then if ev.game_id<>g.id then raise exception 'ID уже занят';end if;return public.ps_api('state',g.id,token);end if;
  actor_id:=(payload->>'team')::uuid;
  if not exists(select 1 from public.ps_teams where id=actor_id and game_id=g.id) then raise exception 'Команда не найдена';end if;
  if op='answer' then
   if clock->>'status'<>'RUNNING' then raise exception 'Приём ответов закрыт или приостановлен';end if;
   select * into task from public.ps_tasks where game_id=g.id and code=payload->>'task';
   if not found or (task.task_type='shot' and task.round_no>issued) then raise exception 'Задача ещё не выдана';end if;
   if task.kind<>'standard' or task.module_id is not null then raise exception 'Интерактивный модуль пока не подключён';end if;
   if exists(select 1 from public.ps_events where game_id=g.id and kind='answer' and not cancelled and data->>'team'=actor_id::text and data->>'task'=task.code) or exists(select 1 from public.ps_submissions where game_id=g.id and team_id=actor_id and task_code=task.code and status<>'CANCELLED') then raise exception 'Команда уже сдавала эту задачу';end if;
   if jsonb_typeof(payload->'correct') is distinct from 'boolean' then raise exception 'Укажите вердикт';end if;correct:=(payload->>'correct')::boolean;
   target_id:=null;if task.task_type='shot' then target_id:=(payload->>'target')::uuid;if target_id is null or target_id=actor_id or not exists(select 1 from public.ps_teams where id=target_id and game_id=g.id) then raise exception 'Выберите соперника';end if;end if;
   insert into public.ps_events(request_id,game_id,time_ms,kind,data) values(req,g.id,now_ms,'answer',jsonb_build_object('team',actor_id,'task',task.code,'target',target_id,'correct',correct,'roll',case when correct and task.task_type='shot' then random() else null end));
  else
   if g.start_ms is null then raise exception 'Игра ещё не началась';end if;
   reason:=trim(coalesce(payload->>'reason',''));val:=payload->>'delta';
   if length(reason) not between 1 and 500 or coalesce(val,'')!~'^-?[0-9]+(\.[0-9]+)?$' or length(val)>30 then raise exception 'Укажите изменение HP и причину';end if;delta:=val::numeric;
   if abs(delta)>1000000 then raise exception 'Слишком большая коррекция';end if;
   insert into public.ps_events(request_id,game_id,time_ms,kind,data) values(req,g.id,now_ms,'hp',jsonb_build_object('team',actor_id,'delta',delta,'reason',reason));
  end if;
 elsif op in ('cancel','undo') then
  req:=(payload->>'id')::uuid;if req is null then raise exception 'Нужен ID запроса';end if;
  if exists(select 1 from public.ps_events where request_id=req and game_id=g.id) then return public.ps_api('state',g.id,token);end if;
  reason:=trim(coalesce(payload->>'reason','Отмена ведущим'));if length(reason) not between 1 and 500 then raise exception 'Укажите причину';end if;
  if op='undo' then select * into ev from public.ps_events where game_id=g.id and kind in ('answer','hp') and not cancelled order by id desc limit 1 for update;
  else select * into ev from public.ps_events where id=(payload->>'event')::bigint and game_id=g.id and kind in ('answer','hp') for update;end if;
  if not found or ev.cancelled then raise exception 'Нет действия для отмены';end if;
  update public.ps_events set cancelled=true,cancel_reason=reason where id=ev.id;
  update public.ps_submissions set status='CANCELLED',note=reason where event_id=ev.id;
  insert into public.ps_events(request_id,game_id,time_ms,kind,data) values(req,g.id,now_ms,'cancel',jsonb_build_object('event',ev.id,'reason',reason));
 elsif op='new' then
  if clock->>'status' in ('RUNNING','PAUSED') then raise exception 'Сначала завершите текущую игру';end if;
  secret:=gen_random_uuid()::text||gen_random_uuid()::text;
  insert into public.ps_games(host_hash,title,rounds,interval_min,online) values(sha256(convert_to(secret,'UTF8')),g.title,g.rounds,g.interval_min,g.online) returning id into gid;
  insert into public.ps_teams(game_id,position,name,token) select gid,position,name,gen_random_uuid()::text||gen_random_uuid()::text from public.ps_teams where game_id=g.id;
  insert into public.ps_tasks(game_id,code,task_type,round_no,n,power,statement,mode,key,bank_task_id,bank_version,kind,module_id,module_version,module_config) select gid,code,task_type,round_no,n,power,statement,mode,key,bank_task_id,bank_version,kind,module_id,module_version,module_config from public.ps_tasks where game_id=g.id;
  return jsonb_build_object('id',gid,'hostToken',secret);
 elsif op='export' then
  return jsonb_build_object('game',to_jsonb(g)-'host_hash','teams',(select jsonb_agg(to_jsonb(t)-'token') from public.ps_teams t where game_id=g.id),'tasks',(select jsonb_agg(to_jsonb(t)) from public.ps_tasks t where game_id=g.id),'ledger',(select coalesce(jsonb_agg(to_jsonb(e) order by id),'[]') from public.ps_events e where game_id=g.id),'submissions',(select coalesce(jsonb_agg(to_jsonb(q) order by time_ms,id),'[]') from public.ps_submissions q where game_id=g.id),'result',public.ps_replay(g.id));
 end if;
 if op in ('configure','start','pause','resume','finish','rounds','issue') then insert into public.ps_events(request_id,game_id,time_ms,kind,data) values(gen_random_uuid(),g.id,now_ms,op,case when op='configure' then payload else payload-'id' end);end if;
 select * into g from public.ps_games where id=g.id;clock:=public.ps_clock(g,now_ms);
 result:=public.ps_replay(g.id)||jsonb_build_object('id',g.id,'title',g.title,'now',now_ms,'clock',clock,'rounds',g.rounds,'interval',g.interval_min,'online',g.online,'pendingCount',(select count(*) from public.ps_submissions where game_id=g.id and status='PENDING'),
 'tasks',(select coalesce(jsonb_agg(to_jsonb(t)-'game_id'-'key'-'mode' order by task_type,round_no,n),'[]') from public.ps_tasks t where game_id=g.id and g.start_ms is not null and (task_type='med' or round_no<=(clock->>'issued')::int)));
 if host or tm.id is not null then result:=result||jsonb_build_object('submissions',(select coalesce(jsonb_agg(to_jsonb(q)-'game_id' order by time_ms,id),'[]') from public.ps_submissions q where game_id=g.id and (host or team_id=tm.id)));end if;
 if host then result:=result||jsonb_build_object('host',true,'draftTasks',(select jsonb_agg(to_jsonb(t)-'game_id' order by task_type,round_no,n) from public.ps_tasks t where game_id=g.id and (task_type='med' or round_no<=g.rounds)),'names',(select jsonb_agg(name order by position) from public.ps_teams where game_id=g.id),'links',(select jsonb_agg(jsonb_build_object('name',name,'token',t.token,'id',t.id) order by position) from public.ps_teams t where game_id=g.id));
 elsif tm.id is not null then result:=result||jsonb_build_object('me',jsonb_build_object('id',tm.id,'name',tm.name));end if;
 return result;
end $$;

revoke all on function public.ps_normal(text,text),public.ps_decide(uuid,boolean,text) from public;

alter table public.od_games add column online boolean not null default true;
create or replace function public.od_api(op text, game uuid default null, token text default '', payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.od_games; t public.od_teams; p public.od_packets; host boolean:=false;
 secret text; names jsonb; task_list jsonb; a jsonb; entry jsonb; task jsonb; outa jsonb:='[]';
 n int; st text; val text; img text; pid uuid; k text; idx int; result jsonb; ts jsonb; ps jsonb;
begin
 if op='create' then
  secret:=gen_random_uuid()::text||gen_random_uuid()::text;
  insert into public.od_games(host_hash,title,tasks) values(sha256(convert_to(secret,'UTF8')),left(coalesce(nullif(trim(payload->>'title'),''),'Оптом дороже'),100),coalesce((select tasks from public.od_templates where id=true),'[]'::jsonb)) returning * into g;
  return jsonb_build_object('game',g.id,'host',secret);
 end if;
 select * into g from public.od_games where id=game;
 if not found then raise exception 'Игра не найдена'; end if;
 host:=length(token)>0 and sha256(convert_to(token,'UTF8'))=g.host_hash;
 if not host and token<>'' then
  select * into t from public.od_teams where game_id=g.id and od_teams.token=od_api.token;
  if not found then raise exception 'Неверная ссылка команды'; end if;
 end if;
 if op not in ('state','photo') then
  select * into g from public.od_games where id=g.id for update;
 end if;
 if op='delivery' then
  if not host or g.started_at is not null or jsonb_typeof(payload->'online') is distinct from 'boolean' then raise exception 'Режим выбирается ведущим до старта';end if;
  update public.od_games set online=(payload->>'online')::boolean where id=g.id;
 elsif op='configure' then
  if not host then raise exception 'Нет доступа ведущего'; end if;
  if g.started_at is not null then raise exception 'После старта команды менять нельзя'; end if;
  names:=payload->'names';
  if coalesce(jsonb_typeof(names),'null')<>'array' or jsonb_array_length(names) not between 3 and 6 then raise exception 'Нужно 3–6 команд'; end if;
  if exists(select 1 from jsonb_array_elements_text(names) x where length(trim(x)) not between 1 and 50) or (select count(distinct trim(x)) from jsonb_array_elements_text(names) x)<>jsonb_array_length(names) then raise exception 'Нужны разные названия до 50 символов'; end if;
  if exists(select 1 from public.od_packets where game_id=g.id) then raise exception 'Уже есть сдачи'; end if;
  -- Reconfigure before start; old capabilities are intentionally invalidated.
  delete from public.od_teams where game_id=g.id;
  for k in select trim(x) from jsonb_array_elements_text(names) x loop
   insert into public.od_teams(game_id,name,token) values(g.id,k,gen_random_uuid()::text||gen_random_uuid()::text);
  end loop;
 elsif op='tasks' then
  if not host then raise exception 'Нет доступа ведущего'; end if;
  task_list:=payload->'tasks';
  if coalesce(jsonb_typeof(task_list),'null')<>'array' or jsonb_array_length(task_list)<>24 then raise exception 'Нужно 24 задачи'; end if;
  for n in 1..24 loop
   task:=task_list->(n-1);
   if (task->>'n')::int is distinct from n or coalesce(task->>'mode','') not in ('number','set','text','manual') or length(coalesce(task->>'title',''))>5000 or length(coalesce(task->>'key',''))>3000 then raise exception 'Неверные настройки задачи %',n; end if;
   if task->>'mode'<>'manual' then
    if nullif(trim(task->>'key'),'') is null then raise exception 'Нет ключа №%',n; end if;
    for k in select unnest(string_to_array(task->>'key','|')) loop
     if public.od_normal(k,task->>'mode') is null then raise exception 'Непонятный ключ №%',n; end if;
    end loop;
   end if;
  end loop;
  update public.od_games set tasks=task_list where id=g.id;
 elsif op='start' then
  if not host then raise exception 'Нет доступа ведущего'; end if;
  if g.started_at is not null then raise exception 'Игра уже запускалась'; end if;
  if jsonb_array_length(g.tasks)<>24 or (select count(*) from public.od_teams where game_id=g.id) not between 3 and 6 then raise exception 'Сохраните команды и 24 задачи'; end if;
  update public.od_games set started_at=clock_timestamp(),ends_at=clock_timestamp()+interval '90 minutes',closed=false where id=g.id;
 elsif op='close' then
  if not host then raise exception 'Нет доступа ведущего'; end if;
  update public.od_games set closed=true where id=g.id;
 elsif op='submit' then
  if host and not g.online then select * into t from public.od_teams where id=(payload->>'team')::uuid and game_id=g.id;
  elsif not g.online then raise exception 'Игра в аудитории: сдайте ответ на листочке ведущему';end if;
  if t.id is null then raise exception 'Нужна ссылка команды'; end if;
  pid:=(payload->>'id')::uuid;
  select * into p from public.od_packets where id=pid;
  if found then
   if p.team_id<>t.id then raise exception 'ID уже занят'; end if;
   return jsonb_build_object('id',pid);
  end if;
  if g.started_at is null or g.closed or clock_timestamp()>=g.ends_at then raise exception 'Приём ответов закрыт'; end if;
  a:=payload->'answers'; img:=coalesce(payload->>'image','');
  if coalesce(jsonb_typeof(a),'null')<>'array' or jsonb_array_length(a) not between 1 and 8 then raise exception 'Нужно от 1 до 8 задач'; end if;
  if img<>'' and (length(img)>2800000 or img !~ '^data:image/jpeg;base64,[A-Za-z0-9+/=]+$') then raise exception 'Неверный формат или размер фото'; end if;
  if (select count(distinct (e->>'n')::int) from jsonb_array_elements(a) e)<>jsonb_array_length(a) then raise exception 'Номера повторяются'; end if;
  for entry in select * from jsonb_array_elements(a) loop
   n:=(entry->>'n')::int; val:=trim(coalesce(entry->>'text',''));
   if n is null or n not between 1 and 24 or length(val)>3000 or (val='' and img='') then raise exception 'Неверный номер или пустой ответ'; end if;
   if exists(select 1 from public.od_packets q cross join lateral jsonb_array_elements(q.answers) e where q.team_id=t.id and (e->>'n')::int=n and coalesce(e->>'cancelled','false')<>'true') then raise exception 'Задача №% уже сдана',n; end if;
   task:=g.tasks->(n-1); st:='pending';
   if task->>'mode'<>'manual' then
    k:=public.od_normal(val,task->>'mode');
    if k is not null and k<>'' then
     if exists(select 1 from unnest(string_to_array(task->>'key','|')) v where public.od_normal(v,task->>'mode')=k) then st:='yes';
     elsif task->>'mode'<>'text' then st:='no'; end if;
    end if;
   end if;
   outa:=outa||jsonb_build_array(jsonb_build_object('n',n,'text',val,'status',st,'cancelled',false));
  end loop;
  insert into public.od_packets(id,game_id,team_id,answers,image) values(pid,g.id,t.id,outa,img);
  return jsonb_build_object('id',pid);
 elsif op in ('judge','cancel') then
  if not host then raise exception 'Нет доступа ведущего'; end if;
  select * into p from public.od_packets where id=(payload->>'id')::uuid and game_id=g.id for update;
  if not found then raise exception 'Комплект не найден'; end if;
  n:=(payload->>'n')::int;
  select ordinality::int-1 into idx from jsonb_array_elements(p.answers) with ordinality where (value->>'n')::int=n;
  if idx is null then raise exception 'Ответ не найден'; end if;
  if op='cancel' then
   outa:=jsonb_set(p.answers,array[idx::text,'cancelled'],'true');
  else
   st:=payload->>'status';
   if st not in ('yes','no','pending') or st is null then raise exception 'Неверный вердикт'; end if;
   outa:=jsonb_set(p.answers,array[idx::text,'status'],to_jsonb(st));
  end if;
  update public.od_packets set answers=outa where id=p.id;
 elsif op='photo' then
  select * into p from public.od_packets where id=(payload->>'id')::uuid and game_id=g.id;
  if not found or not(host or t.id=p.team_id) then raise exception 'Нет доступа к фото'; end if;
  return jsonb_build_object('image',p.image);
 elsif op<>'state' then raise exception 'Неизвестная команда';
 end if;
 select * into g from public.od_games where id=g.id;
 select coalesce(jsonb_agg(x order by (x->>'score')::int desc,x->>'name'),'[]') into ts from (
  select jsonb_build_object('id',tm.id,'name',tm.name,'score',coalesce(sum(public.od_score(q.answers)),0),
   'sent',coalesce(sum((select count(*) from jsonb_array_elements(q.answers) e where coalesce(e->>'cancelled','false')<>'true')),0),
   'pending',count(q.id) filter(where public.od_score(q.answers) is null)) x
  from public.od_teams tm left join public.od_packets q on q.team_id=tm.id where tm.game_id=g.id group by tm.id
 ) z;
 result:=jsonb_build_object('game',g.id,'title',g.title,'online',g.online,'start',g.started_at,'end',g.ends_at,'closed',g.closed,'now',clock_timestamp(),'teams',ts);
 if host or t.id is not null then
  select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'team',q.team_id,'time',q.created_at,'answers',q.answers,'photo',q.image<>'','score',public.od_score(q.answers)) order by q.created_at),'[]') into ps from public.od_packets q where q.game_id=g.id and (host or q.team_id=t.id);
  result:=result||jsonb_build_object('packets',ps,'tasks',(select jsonb_agg(case when host then x else x-'key'-'mode' end order by (x->>'n')::int) from jsonb_array_elements(g.tasks) x));
 end if;
 if host then
  result:=result||jsonb_build_object('host',true,'links',(select coalesce(jsonb_agg(jsonb_build_object('name',name,'token',tm.token) order by name),'[]') from public.od_teams tm where game_id=g.id));
 elsif t.id is not null then result:=result||jsonb_build_object('me',jsonb_build_object('id',t.id,'name',t.name)); end if;
 return result;
end $$;

alter table public.ab_games add column online boolean not null default true;
create or replace function public.ab_api(op text, game uuid default null, token text default '', payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.ab_games; team public.ab_teams; rec public.ab_submissions; host boolean:=false;
 received bigint:=floor(extract(epoch from clock_timestamp())*1000); secret text; gid uuid; names jsonb; task_list jsonb; task jsonb;
 a int; b int; i int; v text; value text; st text; pid uuid; photo jsonb; bytes bytea; mime text; r jsonb; info jsonb; snapshot jsonb;
 nt int; nn int; mins int;
begin
 if op='create' then
  secret:=gen_random_uuid()::text||gen_random_uuid()::text;
  insert into public.ab_games(host_hash,title) values(sha256(convert_to(secret,'UTF8')),left(coalesce(nullif(trim(payload->>'title'),''),'Математическая абака'),100)) returning * into g;
  insert into public.ab_tasks(game_id,theme,n,topic) select g.id,aa.a,bb.b,'Тема '||aa.a from generate_series(1,5) aa(a) cross join generate_series(1,5) bb(b);
  insert into public.ab_teams(game_id,position,name,token) select g.id,n,'Команда '||n,gen_random_uuid()::text||gen_random_uuid()::text from generate_series(1,3) n;
  insert into public.ab_events(game_id,action) values(g.id,'create');
  return jsonb_build_object('id',g.id,'hostToken',secret);
 end if;
 select * into g from public.ab_games where id=game;
 if not found then raise exception 'Игра не найдена'; end if;
 host:=length(token)>0 and sha256(convert_to(token,'UTF8'))=g.host_hash;
 if not host and token<>'' then
  select * into team from public.ab_teams t where t.game_id=g.id and t.token=ab_api.token;
  if not found then raise exception 'Ссылка команды недействительна'; end if;
 end if;
 if op not in ('state','picture') then select * into g from public.ab_games where id=g.id for update; end if;
 if op in ('configure','tasks','start','close','new','review','export','delivery') and not host then raise exception 'Нет доступа ведущего'; end if;
 if op='delivery' then
  if not host or g.start_ms is not null or jsonb_typeof(payload->'online') is distinct from 'boolean' then raise exception 'Режим выбирается ведущим до старта';end if;
  update public.ab_games set online=(payload->>'online')::boolean where id=g.id;
 elsif op='configure' then
  if g.start_ms is not null then raise exception 'Настройки меняются только до старта'; end if;
  nt:=(payload->>'themes')::int;nn:=(payload->>'tasks')::int;mins:=(payload->>'minutes')::int;names:=payload->'names';
  if nt is null or nt not between 1 and 12 or nn is null or nn not between 1 and 12 or mins is null or mins not between 1 and 300 then raise exception 'Тем: 1–12, задач в теме: 1–12, время: 1–300 минут'; end if;
  if coalesce(jsonb_typeof(names),'null')<>'array' or jsonb_array_length(names) not between 1 and 32 then raise exception 'Нужно 1–32 названия'; end if;
  if exists(select 1 from jsonb_array_elements_text(names) x where x is null or length(trim(x)) not between 1 and 60) or (select count(distinct trim(x)) from jsonb_array_elements_text(names) x)<>jsonb_array_length(names) then raise exception 'Нужны разные названия до 60 символов'; end if;
  delete from public.ab_teams where game_id=g.id and position>jsonb_array_length(names);
  for i in 1..jsonb_array_length(names) loop
   insert into public.ab_teams(game_id,position,name,token) values(g.id,i,trim(names->>(i-1)),gen_random_uuid()::text||gen_random_uuid()::text)
   on conflict(game_id,position) do update set name=excluded.name;
  end loop;
  update public.ab_games set themes=nt,tasks_per_theme=nn,minutes=mins where id=g.id;
  insert into public.ab_tasks(game_id,theme,n,topic) select g.id,aa.a,bb.b,'Тема '||aa.a from generate_series(1,nt) aa(a) cross join generate_series(1,nn) bb(b) on conflict do nothing;
  insert into public.ab_events(game_id,action,data) values(g.id,'configure',payload);
 elsif op='tasks' then
  if g.start_ms is not null then raise exception 'Условия и ключи уже зафиксированы на старте'; end if;
  task_list:=payload->'tasks';
  if coalesce(jsonb_typeof(task_list),'null')<>'array' or jsonb_array_length(task_list)<>g.themes*g.tasks_per_theme then raise exception 'Нужно заполнить всё поле задач'; end if;
  if (select count(distinct (x->>'theme',x->>'n')) from jsonb_array_elements(task_list) x)<>jsonb_array_length(task_list) then raise exception 'Повторяются номера задач'; end if;
  for task in select * from jsonb_array_elements(task_list) loop
   a:=(task->>'theme')::int;b:=(task->>'n')::int;
   if a is null or a not between 1 and g.themes or b is null or b not between 1 and g.tasks_per_theme then raise exception 'Неверный номер задачи'; end if;
   if length(trim(coalesce(task->>'topic',''))) not between 1 and 200 or length(coalesce(task->>'text',''))>20000 or length(coalesce(task->>'key',''))>2000 or coalesce(task->>'mode','') not in ('Число','Текст','Набор чисел','Вручную') then raise exception 'Неверные данные задачи %:%',a,b; end if;
   if coalesce(task->>'kind','standard')<>'standard' or task->>'module_id' is not null or coalesce(task->'module_config','{}')<>'{}'::jsonb then raise exception 'Интерактивные модули пока не подключены'; end if;
   if task->>'mode'<>'Вручную' then
    for v in select unnest(string_to_array(coalesce(task->>'key',''),'|')) loop
     if nullif(trim(v),'') is null or public.ab_normal(v,task->>'mode') is null then raise exception 'Некорректный ключ %:%',a,b; end if;
    end loop;
    if nullif(trim(task->>'key'),'') is null then raise exception 'Нет ключа %:%',a,b; end if;
   end if;
   update public.ab_tasks set topic=trim(task->>'topic'),text=coalesce(task->>'text',''),mode=task->>'mode',key=coalesce(task->>'key',''),bank_task_id=(task->>'bank_task_id')::uuid,bank_version=left(task->>'bank_version',100),kind='standard' where game_id=g.id and theme=a and n=b;
  end loop;
  if exists(select 1 from public.ab_tasks where game_id=g.id and theme<=g.themes and n<=g.tasks_per_theme group by theme having count(distinct topic)>1) then raise exception 'В одной теме должны совпадать названия'; end if;
  insert into public.ab_events(game_id,action,data) values(g.id,'tasks_saved',jsonb_build_object('count',jsonb_array_length(task_list)));
 elsif op='start' then
  if g.start_ms is not null then raise exception 'Игра уже запускалась'; end if;
  select jsonb_agg(to_jsonb(t)-'game_id' order by theme,n) into snapshot from public.ab_tasks t where game_id=g.id and theme<=g.themes and n<=g.tasks_per_theme;
  if snapshot is null or jsonb_array_length(snapshot)<>g.themes*g.tasks_per_theme or exists(select 1 from jsonb_array_elements(snapshot) t where nullif(trim(t->>'text'),'') is null or (t->>'mode'<>'Вручную' and nullif(trim(t->>'key'),'') is null)) then raise exception 'Заполните и сохраните все условия и ключи'; end if;
  update public.ab_games set start_ms=received,end_ms=received+minutes*60000,closed=false,frozen_tasks=snapshot where id=g.id;
  insert into public.ab_events(game_id,action) values(g.id,'start');
 elsif op='close' then
  if g.start_ms is null then raise exception 'Игра ещё не началась'; end if;
  update public.ab_games set closed=true where id=g.id;
  insert into public.ab_events(game_id,action) values(g.id,'close');
 elsif op='new' then
  if g.start_ms is not null and not g.closed and received<g.end_ms then raise exception 'Сначала завершите текущую игру'; end if;
  secret:=gen_random_uuid()::text||gen_random_uuid()::text;
  insert into public.ab_games(host_hash,title,themes,tasks_per_theme,minutes,online) values(sha256(convert_to(secret,'UTF8')),g.title,g.themes,g.tasks_per_theme,g.minutes,g.online) returning id into gid;
  insert into public.ab_teams(game_id,position,name,token) select gid,position,name,gen_random_uuid()::text||gen_random_uuid()::text from public.ab_teams where game_id=g.id;
  insert into public.ab_tasks select gid,theme,n,topic,text,mode,key,bank_task_id,bank_version,kind,module_id,module_version,module_config from public.ab_tasks where game_id=g.id;
  insert into public.ab_events(game_id,action,data) values(gid,'copy',jsonb_build_object('source',g.id));
  return jsonb_build_object('id',gid,'hostToken',secret);
 elsif op='submit' then
  if host and not g.online then select * into team from public.ab_teams where id=(payload->>'team')::uuid and game_id=g.id;
  elsif not g.online then raise exception 'Игра в аудитории: сдайте ответ на листочке ведущему';end if;
  if team.id is null then raise exception 'Нужна ссылка команды'; end if;
  pid:=(payload->>'id')::uuid;
  select * into rec from public.ab_submissions where id=pid;
  if found then
   if rec.team_id<>team.id then raise exception 'ID уже занят'; end if;
   return jsonb_build_object('id',rec.id,'status',rec.status);
  end if;
  if g.start_ms is null or received<g.start_ms or g.closed or received>=g.end_ms then raise exception 'Приём ответов закрыт'; end if;
  a:=(payload->>'theme')::int;b:=(payload->>'n')::int;
  if a is null or a not between 1 and g.themes or b is null or b not between 1 and g.tasks_per_theme then raise exception 'Неверный номер задачи'; end if;
  if exists(select 1 from public.ab_submissions where team_id=team.id and theme=a and n=b and status<>'cancelled') then raise exception 'На эту задачу ответ уже отправлен'; end if;
  if exists(select 1 from generate_series(1,b-1) j where not exists(select 1 from public.ab_submissions where team_id=team.id and theme=a and n=j and status<>'cancelled')) then raise exception 'Сначала отправьте предыдущие задачи этой темы'; end if;
  value:=trim(coalesce(payload->>'answer',''));photo:=nullif(payload->'file','null'::jsonb);
  if length(value)>4000 or (value='' and photo is null) then raise exception 'Введите ответ или приложите картинку'; end if;
  task:=(select x from jsonb_array_elements(g.frozen_tasks) x where (x->>'theme')::int=a and (x->>'n')::int=b);
  st:='pending';
  if photo is not null then
   mime:=photo->>'type';v:=photo->>'data';
   if mime is null or mime not in ('image/jpeg','image/png','image/webp') or v is null or length(v)>5600000 or v !~ '^[A-Za-z0-9+/]+={0,2}$' then raise exception 'Картинка: JPG, PNG или WebP до 4 МБ'; end if;
   bytes:=decode(v,'base64');
   if octet_length(bytes) not between 12 and 4194304 or not(case mime when 'image/jpeg' then substring(bytes from 1 for 3)=decode('ffd8ff','hex') when 'image/png' then substring(bytes from 1 for 8)=decode('89504e470d0a1a0a','hex') else substring(bytes from 1 for 4)=convert_to('RIFF','UTF8') and substring(bytes from 9 for 4)=convert_to('WEBP','UTF8') end) then raise exception 'Файл не соответствует формату картинки'; end if;
  elsif task->>'mode'<>'Вручную' then
   v:=public.ab_normal(value,task->>'mode');
   if v is not null then
    if exists(select 1 from unnest(string_to_array(task->>'key','|')) k where public.ab_normal(k,task->>'mode')=v) then st:='yes';
    elsif task->>'mode'<>'Текст' then st:='no'; end if;
   end if;
  end if;
  insert into public.ab_submissions(id,game_id,team_id,received_ms,theme,n,answer,status) values(pid,g.id,team.id,received,a,b,value,st);
  if photo is not null then insert into public.ab_photos(submission_id,mime,data) values(pid,mime,bytes); end if;
  return jsonb_build_object('id',pid,'status',st);
 elsif op='review' then
  pid:=(payload->>'id')::uuid;st:=payload->>'status';v:=trim(coalesce(payload->>'note',''));
  if st is null or st not in ('yes','no','pending','cancelled') or length(v)>1000 then raise exception 'Неверная оценка или длинный комментарий'; end if;
  select * into rec from public.ab_submissions where id=pid and game_id=g.id for update;
  if not found then raise exception 'Сдача не найдена'; end if;
  if rec.status='cancelled' then raise exception 'Сдача уже отменена; команда может ответить заново'; end if;
  update public.ab_submissions set status=st,note=v where id=pid;
  insert into public.ab_events(game_id,action,data) values(g.id,'review',jsonb_build_object('id',pid,'from',rec.status,'to',st,'note',v));
 elsif op='picture' then
  select * into rec from public.ab_submissions where id=(payload->>'id')::uuid and game_id=g.id;
  if not found or not(host or team.id=rec.team_id) or (not host and team.id is null) then raise exception 'Картинка недоступна'; end if;
  select jsonb_build_object('type',ph.mime,'data',encode(ph.data,'base64')) into r from public.ab_photos ph where ph.submission_id=rec.id;
  if r is null then raise exception 'Картинка не найдена'; end if;return r;
 elsif op='export' then
  return jsonb_build_object('game',to_jsonb(g)-'host_hash','tasks',(select jsonb_agg(to_jsonb(t)-'game_id') from public.ab_tasks t where game_id=g.id),
  'teams',(select jsonb_agg(to_jsonb(t)-'token') from public.ab_teams t where game_id=g.id),'results',public.ab_calculate(g.id),
  'submissions',(select coalesce(jsonb_agg(to_jsonb(s) order by received_ms),'[]') from public.ab_submissions s where game_id=g.id),
  'events',(select coalesce(jsonb_agg(to_jsonb(e) order by id),'[]') from public.ab_events e where game_id=g.id));
 elsif op<>'state' or op is null then raise exception 'Неизвестное действие'; end if;
 select * into g from public.ab_games where id=g.id;
 r:=public.ab_calculate(g.id)||jsonb_build_object('id',g.id,'title',g.title,'online',g.online,'now',floor(extract(epoch from clock_timestamp())*1000),
 'start',coalesce(g.start_ms,0),'end',coalesce(g.end_ms,0),'closed',g.closed,'themes',g.themes,'tasksPerTheme',g.tasks_per_theme,'minutes',g.minutes);
 if host or team.id is not null then
  if g.start_ms is null then
   select coalesce(jsonb_agg(to_jsonb(t)-'game_id' order by theme,n),'[]') into info from public.ab_tasks t where game_id=g.id and theme<=g.themes and n<=g.tasks_per_theme;
  else info:=g.frozen_tasks; end if;
  r:=r||jsonb_build_object('taskInfo',case when not host and g.start_ms is null then '[]'::jsonb else (select coalesce(jsonb_agg(x-'key'-'mode' order by (x->>'theme')::int,(x->>'n')::int),'[]') from jsonb_array_elements(info) x) end,
  'records',(select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'time',s.received_ms,'team',s.team_id,'theme',s.theme,'n',s.n,'answer',s.answer,'hasFile',exists(select 1 from public.ab_photos where submission_id=s.id),'status',s.status,'note',s.note) order by s.received_ms,s.id),'[]') from public.ab_submissions s where game_id=g.id and (host or s.team_id=team.id)));
 end if;
 if host then
  r:=r||jsonb_build_object('admin',true,'names',(select jsonb_agg(name order by position) from public.ab_teams where game_id=g.id),
  'links',(select jsonb_agg(jsonb_build_object('name',name,'token',t.token) order by position) from public.ab_teams t where game_id=g.id),
  'draftTasks',info);
 elsif team.id is not null then r:=r||jsonb_build_object('me',jsonb_build_object('id',team.id,'name',team.name)); end if;
 return r;
end $$;

commit;
