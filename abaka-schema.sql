-- Mathematical Abaka, standalone additive migration. No od_* objects are changed.
begin;
create table public.ab_games (
 id uuid primary key default gen_random_uuid(), host_hash bytea not null, title text not null,
 created_at timestamptz not null default now(), themes int not null default 5 check(themes between 1 and 12),
 tasks_per_theme int not null default 5 check(tasks_per_theme between 1 and 12),
 minutes int not null default 90 check(minutes between 1 and 300),
 start_ms bigint, end_ms bigint, closed boolean not null default false, frozen_tasks jsonb
);
create table public.ab_teams (
 id uuid primary key default gen_random_uuid(), game_id uuid not null references public.ab_games(id),
 position int not null check(position between 1 and 32), name text not null check(length(name) between 1 and 60),
 token text not null unique, unique(game_id,position)
);
create table public.ab_tasks (
 game_id uuid not null references public.ab_games(id), theme int not null check(theme between 1 and 12),
 n int not null check(n between 1 and 12), topic text not null, text text not null default '',
 mode text not null default 'Вручную' check(mode in ('Число','Текст','Набор чисел','Вручную')), key text not null default '',
 -- Reserved contracts, no task bank or interactive modules are implemented here.
 bank_task_id uuid, bank_version text, kind text not null default 'standard',
 module_id text, module_version text, module_config jsonb not null default '{}',
 primary key(game_id,theme,n)
);
create table public.ab_submissions (
 id uuid primary key, game_id uuid not null references public.ab_games(id), team_id uuid not null references public.ab_teams(id),
 received_ms bigint not null, theme int not null, n int not null,
 answer text not null check(length(answer)<=4000), status text not null check(status in ('yes','no','pending','cancelled')),
 note text not null default '' check(length(note)<=1000)
);
create unique index ab_one_attempt on public.ab_submissions(team_id,theme,n) where status<>'cancelled';
create index ab_game_submissions on public.ab_submissions(game_id,received_ms);
create table public.ab_photos (
 submission_id uuid primary key references public.ab_submissions(id), mime text not null check(mime in ('image/jpeg','image/png','image/webp')),
 data bytea not null check(octet_length(data) between 1 and 4194304)
);
create table public.ab_events (
 id bigint generated always as identity primary key, game_id uuid not null references public.ab_games(id),
 time timestamptz not null default clock_timestamp(), action text not null, data jsonb not null default '{}'
);
alter table public.ab_games enable row level security;
alter table public.ab_teams enable row level security;
alter table public.ab_tasks enable row level security;
alter table public.ab_submissions enable row level security;
alter table public.ab_photos enable row level security;
alter table public.ab_events enable row level security;
revoke all on public.ab_games,public.ab_teams,public.ab_tasks,public.ab_submissions,public.ab_photos,public.ab_events from anon,authenticated;
revoke all on sequence public.ab_events_id_seq from anon,authenticated;

create function public.ab_number(s text) returns double precision language plpgsql immutable set search_path='' as $$
declare a double precision; b double precision:=1; parts text[]; x text;
begin
 if length(s)>100 then return null; end if;
 parts:=string_to_array(replace(replace(trim(s),'−','-'),',','.'),'/');
 if cardinality(parts) not between 1 and 2 then return null; end if;
 foreach x in array parts loop
  if trim(x)!~'^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$' then return null; end if;
 end loop;
 a:=trim(parts[1])::double precision;
 if cardinality(parts)=2 then b:=trim(parts[2])::double precision; end if;
 if b=0 or (a=trunc(a) and abs(a)>9007199254740991) or (b=trunc(b) and abs(b)>9007199254740991) then return null; end if;
 return a/b;
exception when numeric_value_out_of_range or invalid_text_representation or division_by_zero then return null;
end $$;
create function public.ab_normal(s text, mode text) returns text language plpgsql immutable set search_path='' as $$
declare parts text[]; part text; a double precision; nums double precision[]:='{}';
begin
 if mode='Текст' then return trim(regexp_replace(replace(lower(normalize(s,NFKC)),'ё','е'),'\s+',' ','g')); end if;
 if mode='Число' then return to_jsonb(public.ab_number(s))::text; end if;
 if mode='Набор чисел' then
  parts:=string_to_array(trim(s),';');
  foreach part in array parts loop
   a:=public.ab_number(part);if a is null then return null; end if;nums:=array_append(nums,a);
  end loop;
  return (select jsonb_agg(x order by x)::text from unnest(nums) x);
 end if;
 return null;
end $$;

-- The score is always computed from the accepted history, never supplied by a client.
create function public.ab_calculate(gid uuid) returns jsonb language sql stable set search_path='' as $$
 with g as (select * from public.ab_games where id=gid),
 lines as (
  select 'h'||n id,'Тема '||n label,'h' axis,n num,g.tasks_per_theme*10 base,g.tasks_per_theme required from g cross join lateral generate_series(1,g.themes) n
  union all select 'v'||n,'Столбец '||n,'v',n,n*10,g.themes from g cross join lateral generate_series(1,g.tasks_per_theme) n
 ), finished as (
  select l.id,l.base,t.id team,max(s.received_ms) time
  from lines l cross join public.ab_teams t left join public.ab_submissions s
   on s.team_id=t.id and s.status='yes' and ((l.axis='h' and s.theme=l.num) or (l.axis='v' and s.n=l.num))
  where t.game_id=gid group by l.id,l.base,l.required,t.id having count(s.id)=l.required
 ), awards as (
  select *,time=min(time) over(partition by id) first,base*(case when time=min(time) over(partition by id) then 2 else 1 end) points from finished
 ), totals as (
  select t.id,t.position,t.name,
   coalesce(sum(s.n*10) filter(where s.status='yes'),0) base,
   coalesce((select sum(points) from awards a where a.team=t.id),0) bonus,
   count(s.id) sent,count(s.id) filter(where s.status='pending') pending,
   coalesce(jsonb_agg(jsonb_build_object('theme',s.theme,'n',s.n,'status',s.status) order by s.theme,s.n) filter(where s.id is not null),'[]') cells
  from public.ab_teams t left join public.ab_submissions s on s.team_id=t.id and s.status<>'cancelled'
  where t.game_id=gid group by t.id
 ), ranked as (
  select *,base+bonus total,rank() over(order by base+bonus desc,bonus desc) place from totals
 )
 select jsonb_build_object('teams',coalesce((select jsonb_agg(to_jsonb(r)-'position' order by r.place,r.position) from ranked r),'[]'),
 'lines',coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'label',l.label,'base',l.base,'awards',coalesce((select jsonb_agg(jsonb_build_object('team',a.team,'time',a.time,'points',a.points,'first',a.first) order by a.time,a.team) from awards a where a.id=l.id),'[]')) order by l.axis,l.num) from lines l),'[]'),
 'provisional',exists(select 1 from public.ab_submissions where game_id=gid and status='pending'))
$$;

create function public.ab_api(op text, game uuid default null, token text default '', payload jsonb default '{}')
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
 if op in ('configure','tasks','start','close','new','review','export') and not host then raise exception 'Нет доступа ведущего'; end if;
 if op='configure' then
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
  insert into public.ab_games(host_hash,title,themes,tasks_per_theme,minutes) values(sha256(convert_to(secret,'UTF8')),g.title,g.themes,g.tasks_per_theme,g.minutes) returning id into gid;
  insert into public.ab_teams(game_id,position,name,token) select gid,position,name,gen_random_uuid()::text||gen_random_uuid()::text from public.ab_teams where game_id=g.id;
  insert into public.ab_tasks select gid,theme,n,topic,text,mode,key,bank_task_id,bank_version,kind,module_id,module_version,module_config from public.ab_tasks where game_id=g.id;
  insert into public.ab_events(game_id,action,data) values(gid,'copy',jsonb_build_object('source',g.id));
  return jsonb_build_object('id',gid,'hostToken',secret);
 elsif op='submit' then
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
 r:=public.ab_calculate(g.id)||jsonb_build_object('id',g.id,'title',g.title,'now',floor(extract(epoch from clock_timestamp())*1000),
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
revoke all on function public.ab_number(text),public.ab_normal(text,text),public.ab_calculate(uuid),public.ab_api(text,uuid,text,jsonb) from public;
grant execute on function public.ab_api(text,uuid,text,jsonb) to anon,authenticated;
commit;
