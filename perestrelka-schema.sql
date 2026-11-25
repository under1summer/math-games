-- Independent Perestrelka schema. Does not alter od_* or ab_*.
begin;
create table public.ps_games (
 id uuid primary key default gen_random_uuid(),host_hash bytea not null,title text not null,
 created_at timestamptz not null default now(),status text not null default 'READY' check(status in ('READY','RUNNING','PAUSED','FINISHED')),
 online boolean not null default true,rounds int not null default 8 check(rounds between 1 and 120),interval_min int not null default 15 check(interval_min between 1 and 120),
 start_ms bigint,paused_at_ms bigint,pause_total_ms bigint not null default 0,finished_elapsed_ms bigint,manual_rounds int not null default 0
);
create table public.ps_teams (
 id uuid primary key default gen_random_uuid(),game_id uuid not null references public.ps_games(id),
 position int not null check(position between 1 and 16),name text not null check(length(name) between 1 and 45),token text not null unique,
 unique(game_id,position)
);
create table public.ps_tasks (
 game_id uuid not null references public.ps_games(id),code text not null,task_type text not null check(task_type in ('shot','med')),
 round_no int,n int not null,power int not null default 0,statement text not null default '',mode text not null default 'manual' check(mode in ('number','set','text','manual')),key text not null default '',
 bank_task_id uuid,bank_version text,kind text not null default 'standard',module_id text,module_version text,module_config jsonb not null default '{}',
 primary key(game_id,code)
);
create table public.ps_events (
 id bigint generated always as identity primary key,request_id uuid not null unique,game_id uuid not null references public.ps_games(id),
 time_ms bigint not null,kind text not null,data jsonb not null,cancelled boolean not null default false,cancel_reason text not null default ''
);

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

create index ps_game_events on public.ps_events(game_id,id);
create unique index ps_one_attempt on public.ps_events(game_id,(data->>'team'),(data->>'task')) where kind='answer' and not cancelled;
alter table public.ps_games enable row level security;
alter table public.ps_teams enable row level security;
alter table public.ps_tasks enable row level security;
alter table public.ps_events enable row level security;
revoke all on public.ps_games,public.ps_teams,public.ps_tasks,public.ps_events from anon,authenticated;
revoke all on sequence public.ps_events_id_seq from anon,authenticated;

create function public.ps_seed(gid uuid,lim int) returns void language plpgsql set search_path='' as $$
begin
 insert into public.ps_tasks(game_id,code,task_type,round_no,n)
 select gid,'s:'||rr.r||':'||nn.n,'shot',rr.r,nn.n from generate_series(1,lim) rr(r) cross join generate_series(1,6) nn(n) on conflict do nothing;
 insert into public.ps_tasks(game_id,code,task_type,n,power)
 select gid,'m:'||x.n,'med',x.n,case when x.n<=4 then 2 when x.n<=8 then 5 when x.n<=12 then 10 when x.n<=16 then 15 when x.n<=18 then 20 else 25 end
 from generate_series(1,20) x(n) on conflict do nothing;
end $$;
create function public.ps_clock(g public.ps_games,now_ms bigint) returns jsonb language plpgsql immutable set search_path='' as $$
declare elapsed bigint:=0;phase text:=g.status;issued int:=0;duration bigint:=g.rounds*g.interval_min*60000::bigint;
begin
 if g.start_ms is not null then
  elapsed:=case when g.status='FINISHED' then g.finished_elapsed_ms when g.status='PAUSED' then g.paused_at_ms-g.start_ms-g.pause_total_ms else now_ms-g.start_ms-g.pause_total_ms end;
  elapsed:=greatest(0,least(elapsed,duration));
  if g.status='RUNNING' and elapsed>=duration then phase:='FINISHED'; end if;
  issued:=least(g.rounds,greatest(1,g.manual_rounds,(elapsed/(g.interval_min*60000))::int+1));
 end if;
 return jsonb_build_object('status',phase,'elapsed',elapsed,'remaining',duration-elapsed,'issued',issued,'duration',duration);
end $$;

-- Replay uses each shot's stored roll. Cancelling an answer never rerolls later shots.
create function public.ps_replay(gid uuid) returns jsonb language plpgsql stable set search_path='' as $$
declare teams jsonb;history jsonb:='[]';ev public.ps_events;t jsonb;target jsonb;idx int;ti int;hp numeric;delta numeric;
 k int;attempts int;chance numeric;hit boolean;correct boolean;damage numeric;heal numeric;label text;task public.ps_tasks;
begin
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'position',position,'hp',100,'k',0,'n',0,'accuracy',0.5) order by position),'[]') into teams from public.ps_teams where game_id=gid;
 for ev in select * from public.ps_events where game_id=gid order by id loop
  if ev.kind not in ('answer','hp') then continue; end if;
  if ev.cancelled then history:=history||jsonb_build_array(jsonb_build_object('id',ev.id,'time',ev.time_ms,'kind',ev.kind,'team',ev.data->>'team','task',ev.data->>'task','cancelled',true,'reason',ev.cancel_reason));continue;end if;
  select ordinality::int-1 into idx from jsonb_array_elements(teams) with ordinality where value->>'id'=ev.data->>'team';
  if idx is null then raise exception 'Повреждён журнал команд'; end if;
  t:=teams->idx;hp:=(t->>'hp')::numeric;k:=(t->>'k')::int;attempts:=(t->>'n')::int;
  if ev.kind='hp' then
   delta:=(ev.data->>'delta')::numeric;teams:=jsonb_set(teams,array[idx::text,'hp'],to_jsonb(greatest(0,hp+delta)));
   history:=history||jsonb_build_array(jsonb_build_object('id',ev.id,'time',ev.time_ms,'kind','hp','team',ev.data->>'team','delta',delta,'before',hp,'after',greatest(0,hp+delta),'reason',ev.data->>'reason','cancelled',false));continue;
  end if;
  select * into task from public.ps_tasks where game_id=gid and code=ev.data->>'task';
  chance:=(1+k)::numeric/(2+attempts);correct:=(ev.data->>'correct')::boolean;damage:=0;heal:=0;hit:=false;
  if correct and task.task_type='med' then
   heal:=task.power;teams:=jsonb_set(teams,array[idx::text,'hp'],to_jsonb(hp+heal));
  elsif correct and task.task_type='shot' then
   hit:=(ev.data->>'roll')::numeric<chance;
   select ordinality::int-1 into ti from jsonb_array_elements(teams) with ordinality where value->>'id'=ev.data->>'target';
   if ti is null then raise exception 'Повреждена цель выстрела';end if;
   if hit then damage:=greatest(3,hp/5);target:=teams->ti;teams:=jsonb_set(teams,array[ti::text,'hp'],to_jsonb(greatest(0,(target->>'hp')::numeric-damage)));end if;
  end if;
  attempts:=attempts+1;if correct then k:=k+1;end if;
  teams:=jsonb_set(teams,array[idx::text,'k'],to_jsonb(k));teams:=jsonb_set(teams,array[idx::text,'n'],to_jsonb(attempts));teams:=jsonb_set(teams,array[idx::text,'accuracy'],to_jsonb((1+k)::numeric/(2+attempts)));
  history:=history||jsonb_build_array(jsonb_build_object('id',ev.id,'time',ev.time_ms,'kind','answer','team',ev.data->>'team','task',task.code,'taskType',task.task_type,'round',task.round_no,'n',task.n,'power',task.power,'target',ev.data->>'target','correct',correct,'chance',chance,'roll',ev.data->'roll','hit',hit,'damage',damage,'heal',heal,'cancelled',false));
 end loop;
 return jsonb_build_object('teams',(select coalesce(jsonb_agg(x||jsonb_build_object('place',(select count(*)+1 from jsonb_array_elements(teams) z where (z->>'hp')::numeric>(x->>'hp')::numeric)) order by (x->>'hp')::numeric desc,(x->>'position')::int),'[]') from jsonb_array_elements(teams) x),'history',history);
end $$;

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

create function public.ps_api(op text,game uuid default null,token text default '',payload jsonb default '{}') returns jsonb
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
revoke all on function public.ps_seed(uuid,int),public.ps_clock(public.ps_games,bigint),public.ps_replay(uuid),public.ps_api(text,uuid,text,jsonb),public.ps_normal(text,text),public.ps_decide(uuid,boolean,text) from public;
grant execute on function public.ps_api(text,uuid,text,jsonb) to anon,authenticated;
commit;
