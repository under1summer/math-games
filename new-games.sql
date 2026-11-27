-- Five rule-specific games on the shared platform. Apply once after saved-games.sql.
-- Additive only: existing game routines, grants, schemas and game rows are unchanged.
begin;
create table public.ng_games(id uuid primary key default gen_random_uuid(),kind text not null check(kind in('p52','xo','maze','bonus','domino')),host_hash bytea not null,title text not null,online boolean not null default true,minutes int not null check(minutes between 1 and 1440),settings jsonb not null default '{}',started_at timestamptz,ends_at timestamptz,closed boolean not null default false,created_at timestamptz not null default now());
create table public.ng_lifecycle(game_kind text not null,game_id uuid primary key references public.ng_games(id)on delete cascade,activity_at timestamptz not null default now(),finished_at timestamptz,archived boolean not null default false,result jsonb);
alter table public.ng_lifecycle enable row level security;revoke all on public.ng_lifecycle from public,anon,authenticated;
create table public.ng_teams(id uuid primary key default gen_random_uuid(),game_id uuid not null references public.ng_games(id)on delete cascade,position int not null,name text not null,token text not null,unique(game_id,position));
create table public.ng_slots(game_id uuid references public.ng_games(id)on delete cascade,code text,position int not null,meta jsonb not null,primary key(game_id,code));
create table public.ng_submissions(seq bigint generated always as identity unique,id uuid primary key,game_id uuid not null references public.ng_games(id)on delete cascade,team_id uuid not null references public.ng_teams(id)on delete cascade,code text not null,received_at timestamptz not null default clock_timestamp(),answer text not null default '',example text not null default '',solution jsonb,files jsonb not null default '[]',bonus text,status text not null check(status in('yes','no','pending','cancelled')),note text not null default '',foreign key(game_id,code)references public.ng_slots(game_id,code));
create index on public.ng_submissions(game_id,team_id,seq);
create table public.ng_issued(game_id uuid,team_id uuid references public.ng_teams(id)on delete cascade,code text,primary key(team_id,code),foreign key(game_id,code)references public.ng_slots(game_id,code)on delete cascade);
create table public.ng_leases(game_id uuid,code text,team_id uuid unique references public.ng_teams(id)on delete cascade,primary key(game_id,code),foreign key(game_id,code)references public.ng_slots(game_id,code)on delete cascade);
create table public.ng_events(id bigint generated always as identity primary key,game_id uuid references public.ng_games(id)on delete cascade,created_at timestamptz not null default clock_timestamp(),action text not null,data jsonb not null default '{}');
alter table public.ng_games enable row level security;alter table public.ng_teams enable row level security;alter table public.ng_slots enable row level security;alter table public.ng_submissions enable row level security;alter table public.ng_issued enable row level security;alter table public.ng_leases enable row level security;alter table public.ng_events enable row level security;
revoke all on public.ng_games,public.ng_teams,public.ng_slots,public.ng_submissions,public.ng_issued,public.ng_leases,public.ng_events from public,anon,authenticated;

create function public.ng_host(k text,g uuid,t text)returns boolean language sql stable security definer set search_path=''as $$select coalesce((select length(t)>0 and host_hash=sha256(convert_to(t,'UTF8'))from public.ng_games where id=g and kind=k),false)$$;
create function public.ng_setup(g uuid)returns void language plpgsql set search_path=''as $$declare gg public.ng_games;n int;a int;b int;meta jsonb;begin
select *into strict gg from public.ng_games where id=g;
n:=case gg.kind when 'xo'then 25 when 'maze'then 24 when 'bonus'then 24 when 'p52' then(gg.settings->>'count')::int else((gg.settings->>'max_pip')::int+1)*((gg.settings->>'max_pip')::int+2)/2 end;
if gg.kind='domino'then n:=0;for a in 0..(gg.settings->>'max_pip')::int loop for b in a..(gg.settings->>'max_pip')::int loop n:=n+1;insert into public.ng_slots values(g,n::text,n,jsonb_build_object('left',a,'right',b))on conflict(game_id,code)do nothing;end loop;end loop;
else for a in 1..n loop meta:=case gg.kind when 'xo'then jsonb_build_object('row',(a-1)/5+1,'col',(a-1)%5+1)when 'maze'then jsonb_build_object('block',(a-1)/4+1,'price',(a-1)/4+2,'extra',case when a in(3,7,11,15)then a+3 end)when 'bonus'then jsonb_build_object('price',(a-1)/8+3,'order',(a-1)%8+1)else '{}'::jsonb end;insert into public.ng_slots values(g,a::text,a,meta)on conflict(game_id,code)do nothing;end loop;end if;
insert into public.mg_task_copies(game_kind,game_id,code,content)select gg.kind,g,s.code,public.mg_validate('{"condition":"","mode":"manual","key":"","kind":"standard"}')from public.ng_slots s where game_id=g on conflict do nothing;
end $$;

-- One scoreboard projector. Scoring never depends on the browser or on team-supplied prices.
create function public.ng_board(g uuid,team uuid)returns jsonb language plpgsql stable set search_path=''as $$
#variable_conflict use_column
declare gg public.ng_games;slot public.ng_slots;first_yes bigint;yes_count int;no_count int;pending_count int;tries int;value int;total int:=0;sent int:=0;pending_all int:=0;available_count int:=0;done_count int:=0;done boolean;allowed boolean;st text;cells jsonb:='[]';remaining jsonb;left_count int;bon text;lim int;begin
select *into strict gg from public.ng_games where id=g;
for slot in select *from public.ng_slots where game_id=g order by position loop
select count(*),count(*)filter(where status='yes'),count(*)filter(where status='no'),count(*)filter(where status='pending'),min(seq)filter(where status='yes')into tries,yes_count,no_count,pending_count,first_yes from public.ng_submissions where game_id=g and team_id=team and code=slot.code and status<>'cancelled';
value:=0;lim:=case when gg.kind='domino'and slot.meta->>'left'='0'and slot.meta->>'right'='0'then 1 when gg.kind='domino'then 2 else 1 end;
if gg.kind='p52' then
if first_yes is not null then select count(*)into no_count from public.ng_submissions where game_id=g and team_id=team and code=slot.code and status='no'and seq<first_yes;value:=5-2*no_count;else value:=-2*no_count;end if;done:=first_yes is not null;
elsif gg.kind='xo'then done:=tries>0;if yes_count>0 then select 1+count(*)into value from public.ng_slots s where s.game_id=g and abs((s.meta->>'row')::int-(slot.meta->>'row')::int)+abs((s.meta->>'col')::int-(slot.meta->>'col')::int)=1 and exists(select 1 from public.ng_submissions q where q.game_id=g and q.team_id=team and q.code=s.code and q.status='yes');end if;
elsif gg.kind='maze'then done:=tries>0;if yes_count>0 then value:=(slot.meta->>'price')::int;end if;
elsif gg.kind='bonus'then done:=tries>0;if yes_count>0 then select bonus into bon from public.ng_submissions where game_id=g and team_id=team and code=slot.code and status='yes'order by seq limit 1;value:=case left(bon,1)when '+'then(slot.meta->>'price')::int+substring(bon,2)::int else(slot.meta->>'price')::int*substring(bon,2)::int end;end if;
else done:=yes_count>0 or tries>=lim;select seq into first_yes from public.ng_submissions where game_id=g and team_id=team and code=slot.code and status='yes'order by seq limit 1;if first_yes is not null then select count(*)into no_count from public.ng_submissions where game_id=g and team_id=team and code=slot.code and status<>'cancelled'and seq<first_yes;value:=case when lim=1 then 10 when no_count=0 then(slot.meta->>'left')::int+(slot.meta->>'right')::int else greatest((slot.meta->>'left')::int,(slot.meta->>'right')::int)end;elsif tries>=lim and pending_count=0 then value:=-least((slot.meta->>'left')::int,(slot.meta->>'right')::int);end if;end if;
st:=case when pending_count>0 then 'pending'when yes_count>0 then 'yes'when no_count>0 then 'no'else 'empty'end;
allowed:=not done and pending_count=0 and case when gg.kind='domino'then exists(select 1 from public.ng_leases where game_id=g and team_id=team and code=slot.code)else exists(select 1 from public.ng_issued where game_id=g and team_id=team and code=slot.code)end;
if gg.kind='p52' then allowed:=allowed and yes_count=0;end if;
total:=total+value;sent:=sent+tries;pending_all:=pending_all+pending_count;if allowed then available_count:=available_count+1;end if;if done and pending_count=0 then done_count:=done_count+1;end if;
cells:=cells||jsonb_build_array(jsonb_build_object('code',slot.code,'status',st,'score',value,'attempts',tries,'wrong',no_count,'done',done,'available',allowed,'meta',slot.meta));
end loop;
remaining:='{}';for bon,lim in select *from(values('+1',6),('+2',4),('+3',2),('x2',6),('x3',4),('x4',2))v(b,n)loop select lim-count(*)into left_count from public.ng_submissions where game_id=g and team_id=team and bonus=bon and status<>'cancelled';remaining:=remaining||jsonb_build_object(bon,left_count);end loop;
return jsonb_build_object('total',total,'score',total,'sent',sent,'pending',pending_all,'available',available_count,'done',done_count,'cells',cells,'bonuses',remaining,'finished',done_count=jsonb_array_length(cells));end $$;

create function public.ng_issue(g uuid,team uuid,code text,status text)returns void language plpgsql set search_path=''as $$declare gg public.ng_games;n int;next_code text;b jsonb;begin
select *into gg from public.ng_games where id=g;n:=code::int;
if gg.kind in('maze','bonus')then next_code:=(n+1)::text;if gg.kind='maze'and n<24 or gg.kind='bonus'and n%8<>0 then insert into public.ng_issued select g,team,next_code where exists(select 1 from public.ng_slots where game_id=g and ng_slots.code=next_code)on conflict do nothing;end if;end if;
if gg.kind='maze'and status='yes'and n in(3,7,11,15)then insert into public.ng_issued values(g,team,(n+3)::text)on conflict do nothing;end if;
if gg.kind='domino'then b:=public.ng_board(g,team);if exists(select 1 from jsonb_array_elements(b->'cells')x where x->>'code'=code and(x->>'done')::boolean and x->>'status'<>'pending')then delete from public.ng_leases where game_id=g and team_id=team and ng_leases.code=ng_issue.code;end if;end if;
end $$;

create function public.ng_state(g uuid,t text default '')returns jsonb language plpgsql stable security definer set search_path=''as $$
#variable_conflict use_column
declare gg public.ng_games;host boolean;me public.ng_teams;tm public.ng_teams;teams jsonb:='[]';board jsonb;tasks jsonb;records jsonb;links jsonb;arch jsonb;begin
select *into strict gg from public.ng_games where id=g;host:=public.ng_host(gg.kind,g,t);if t<>''and not host then select *into me from public.ng_teams where game_id=g and token=t;if not found then raise exception 'Ссылка команды недействительна';end if;end if;
select result into arch from public.ng_lifecycle where game_kind=gg.kind and game_id=g and archived;if arch is not null then return arch||jsonb_build_object('archived',true);end if;
for tm in select *from public.ng_teams where game_id=g order by position loop board:=public.ng_board(g,tm.id);teams:=teams||jsonb_build_array(jsonb_build_object('id',tm.id,'name',tm.name,'position',tm.position)|| (board-'bonuses'));end loop;
select coalesce(jsonb_agg(jsonb_build_object('code',s.code,'position',s.position,'meta',s.meta,'holder',(select team_id from public.ng_leases where game_id=g and code=s.code),'issued',exists(select 1 from public.ng_issued where game_id=g and team_id=me.id and code=s.code),'content',case when host then cp.content when me.id is not null and gg.started_at is not null and case when gg.kind='domino'then exists(select 1 from public.ng_leases where game_id=g and team_id=me.id and code=s.code)else exists(select 1 from public.ng_issued where game_id=g and team_id=me.id and code=s.code)end then cp.content-'key'else null end)order by s.position),'[]')into tasks from public.ng_slots s left join public.mg_task_copies cp on cp.game_kind=gg.kind and cp.game_id=g and cp.code=s.code where s.game_id=g;
select coalesce(jsonb_agg(to_jsonb(q)order by q.seq),'[]')into records from public.ng_submissions q where game_id=g and(host or team_id=me.id);
if host then select jsonb_agg(jsonb_build_object('id',id,'name',name,'token',token)order by position)into links from public.ng_teams where game_id=g;end if;
return jsonb_build_object('id',g,'kind',gg.kind,'title',gg.title,'settings',gg.settings,'minutes',gg.minutes,'online',gg.online,'start',gg.started_at,'end',gg.ends_at,'closed',gg.closed,'now',clock_timestamp(),'host',host,'me',case when me.id is not null then jsonb_build_object('id',me.id,'name',me.name)end,'teams',teams,'tasks',tasks,'records',records,'links',coalesce(links,'[]'),'bonuses',case when me.id is not null then public.ng_board(g,me.id)->'bonuses'end);
end $$;

create function public.ng_tasks(k text,g uuid,t text,op text,payload jsonb default '{}')returns jsonb language plpgsql security definer set search_path=''as $$
#variable_conflict use_column
declare gg public.ng_games;row jsonb;c jsonb;bid uuid;ver int;expected int;rows jsonb;meta jsonb;slot public.ng_slots;begin
select *into strict gg from public.ng_games where id=g and kind=k for update;if not public.ng_host(k,g,t)then raise exception 'Нужна ссылка ведущего';end if;
if op='get'then select coalesce(jsonb_agg(jsonb_build_object('code',s.code,'number',s.position,'meta',s.meta,'content',cp.content,'bank_id',cp.bank_id,'bank_version',cp.bank_version)order by s.position),'[]')into rows from public.ng_slots s join public.mg_task_copies cp on cp.game_kind=k and cp.game_id=g and cp.code=s.code where s.game_id=g;return jsonb_build_object('rows',rows,'locked',gg.started_at is not null);end if;
if op<>'save'or gg.started_at is not null then raise exception 'Задачи меняются до старта';end if;
select count(*)into expected from public.ng_slots where game_id=g;rows:=payload->'rows';if jsonb_typeof(rows)is distinct from 'array'or jsonb_array_length(rows)<>expected or(select count(distinct x->>'code')from jsonb_array_elements(rows)x)<>expected then raise exception 'Нужно сохранить все разные позиции задач';end if;
for row in select *from jsonb_array_elements(rows)loop select *into slot from public.ng_slots where game_id=g and code=row->>'code';if not found then raise exception 'Неизвестная позиция';end if;c:=public.mg_validate(row->'content');bid:=(row->>'bank_id')::uuid;ver:=(row->>'bank_version')::int;
if bid is not null and not exists(select 1 from public.mg_task_copies where game_kind=k and game_id=g and code=slot.code and bank_id=bid and bank_version=ver and content=c)and not exists(select 1 from public.mg_bank_tasks b join public.mg_bank_versions v on v.task_id=b.id and v.version=ver where b.id=bid and b.owner_id=auth.uid()and v.content=c)then raise exception 'Версия банка недоступна';end if;
meta:=coalesce(row->'meta',slot.meta);if meta<>slot.meta then raise exception 'Параметры позиции % заданы правилами. Выберите размер набора в настройках игры',slot.code;end if;
update public.mg_task_copies set content=c,bank_id=bid,bank_version=ver where game_kind=k and game_id=g and code=slot.code;end loop;
update public.ng_lifecycle set activity_at=now()where game_kind=k and game_id=g;return public.ng_tasks(k,g,t,'get');end $$;

create function public.ng_api(op text,game uuid default null,token text default '',payload jsonb default '{}')returns jsonb language plpgsql security definer set search_path=''as $$
#variable_conflict use_column
declare gg public.ng_games;tm public.ng_teams;host boolean;secret text;k text;minutes int;settings jsonb;names jsonb;n int;i int;slot public.ng_slots;cell jsonb;board jsonb;pid uuid;sub public.ng_submissions;st text;c jsonb;answer text;example text;files jsonb;sol jsonb;bon text;reason text;begin
if op='create'then
k:=payload->>'kind';if k not in('p52','xo','maze','bonus','domino')or k is null then raise exception 'Выберите игру';end if;
minutes:=case when k='bonus'then 120 else coalesce((payload->>'minutes')::int,90)end;if minutes not between 1 and 1440 then raise exception 'Время: 1–1440 минут';end if;
settings:=jsonb_build_object('count',coalesce((payload->>'count')::int,12),'max_pip',coalesce((payload->>'max_pip')::int,6));if(settings->>'count')::int not between 1 and 1000 or(settings->>'max_pip')::int not between 1 and 12 then raise exception 'Задач: 1–1000; максимум на домино: 1–12';end if;
names:=coalesce(payload->'names','["Команда 1","Команда 2","Команда 3"]');if jsonb_typeof(names)is distinct from 'array'or jsonb_array_length(names)not between 1 and 32 or exists(select 1 from jsonb_array_elements_text(names)x where x is null or length(trim(x))not between 1 and 60)or(select count(distinct trim(x))from jsonb_array_elements_text(names)x)<>jsonb_array_length(names)then raise exception 'Нужно 1–32 разных названия команд до 60 символов';end if;
secret:=gen_random_uuid()::text||gen_random_uuid()::text;insert into public.ng_games(kind,host_hash,title,minutes,settings,online)values(k,sha256(convert_to(secret,'UTF8')),left(coalesce(nullif(trim(payload->>'title'),''),case k when 'p52'then 'Плюс 5 — минус 2'when 'xo'then 'Математические крестики-нолики'when 'maze'then 'Лабиринт'when 'bonus'then 'Бонусы'else 'Математическое домино'end),100),minutes,settings,coalesce((payload->>'online')::boolean,true))returning *into gg;
for i in 1..jsonb_array_length(names)loop insert into public.ng_teams(game_id,position,name,token)values(gg.id,i,trim(names->>(i-1)),gen_random_uuid()::text||gen_random_uuid()::text);end loop;perform public.ng_setup(gg.id);return jsonb_build_object('id',gg.id,'hostToken',secret,'kind',k);
end if;
select *into gg from public.ng_games where id=game;if not found then raise exception 'Игра не найдена';end if;
if op='state'then return public.ng_state(game,token);end if;
select *into gg from public.ng_games where id=game for update;host:=public.ng_host(gg.kind,game,token);if not host then select *into tm from public.ng_teams where game_id=game and ng_teams.token=ng_api.token;if not found then raise exception 'Нет доступа';end if;end if;
if exists(select 1 from public.ng_lifecycle where game_kind=gg.kind and game_id=game and archived)then raise exception 'Подробные данные игры уже очищены';end if;
if op in('start','finish','review','return')and not host then raise exception 'Нужна ссылка ведущего';end if;
if op='start'then
if gg.started_at is not null then raise exception 'Игра уже запускалась';end if;if gg.online and exists(select 1 from public.ng_slots s left join public.mg_task_copies c on c.game_kind=gg.kind and c.game_id=game and c.code=s.code where s.game_id=game and(nullif(trim(c.content->>'condition'),'')is null or(c.content->>'kind'<>'cutting'and c.content->>'mode'<>'manual'and nullif(trim(c.content->>'key'),'')is null)))then raise exception 'Заполните и сохраните все условия и ключи';end if;
update public.ng_games set started_at=clock_timestamp(),ends_at=clock_timestamp()+make_interval(mins=>gg.minutes)where id=game;
insert into public.ng_issued select game,t.id,s.code from public.ng_teams t cross join public.ng_slots s where t.game_id=game and s.game_id=game and(gg.kind in('p52','xo')or gg.kind='maze'and s.position=1 or gg.kind='bonus'and s.position in(1,9,17))on conflict do nothing;
elsif op='finish'then if gg.started_at is null then raise exception 'Игра ещё не началась';end if;update public.ng_games set closed=true where id=game;
elsif op in('submit','choose')then
if gg.started_at is null or gg.closed or gg.ends_at<=clock_timestamp()then raise exception 'Приём ответов закрыт';end if;
if host then if gg.online then raise exception 'Используйте личную ссылку команды';end if;select *into tm from public.ng_teams where game_id=game and id=(payload->>'team')::uuid;if not found then raise exception 'Нет команды';end if;elsif not gg.online then raise exception 'Сдайте ответ на листочке ведущему';end if;
select *into slot from public.ng_slots where game_id=game and code=payload->>'code';if not found then raise exception 'Нет задачи';end if;board:=public.ng_board(game,tm.id);select x into cell from jsonb_array_elements(board->'cells')x where x->>'code'=slot.code;
if op='choose'then
if gg.kind<>'domino'then raise exception 'Выбор карточки доступен только в домино';end if;if(cell->>'done')::boolean or(board->>'pending')::int>0 then raise exception 'Карточка уже завершена или есть ответ на проверке';end if;if exists(select 1 from public.ng_leases where game_id=game and team_id=tm.id and code=slot.code)then return public.ng_state(game,token);end if;if exists(select 1 from public.ng_leases where game_id=game and(team_id=tm.id or code=slot.code))then raise exception 'Карточка занята или у команды уже есть карточка';end if;insert into public.ng_leases values(game,slot.code,tm.id);insert into public.ng_issued values(game,tm.id,slot.code)on conflict do nothing;
else
pid:=(payload->>'id')::uuid;if pid is null then raise exception 'Нужен ID отправки';end if;select *into sub from public.ng_submissions where id=pid;if found then if sub.game_id<>game or sub.team_id<>tm.id then raise exception 'Отправка недоступна';end if;return public.ng_state(game,token);end if;
if not(cell->>'available')::boolean then raise exception 'Задача недоступна для сдачи';end if;
answer:=coalesce(payload->>'answer','');example:=coalesce(payload->>'example','');files:=coalesce(payload->'files','[]');sol:=payload->'solution';if length(answer)>6000 or length(example)>6000 or(length(trim(answer))=0 and length(trim(example))=0 and jsonb_array_length(files)=0 and(sol is null or sol='null'))then raise exception 'Добавьте ответ, решение или файл';end if;
if gg.kind='p52'and not host and length(trim(example))=0 and jsonb_array_length(files)=0 and(sol is null or sol='null')then raise exception 'Добавьте пример реализации: текст, интерактивное решение или файл';end if;
select content into c from public.mg_task_copies where game_kind=gg.kind and game_id=game and code=slot.code;perform public.mg_bind_files(gg.kind,game,tm.id,slot.code,pid,files,case when host and not gg.online then 'optional'else c->>'attachments'end);
if c->>'kind'='cutting'and sol is not null and sol<>'null'::jsonb then st:=public.mg_cut_check(c->'module_config',sol);elsif c->>'mode'='manual'or length(trim(answer))=0 then st:='pending';else st:=case when public.od_normal(answer,c->>'mode')is null then 'pending'when public.od_normal(answer,c->>'mode')=any(select public.od_normal(x,c->>'mode')from unnest(string_to_array(c->>'key','|'))x)then 'yes'else 'no'end;end if;
-- In +5/-2 an example must be judged as well: matching a number is never sufficient.
if gg.kind='p52'and st='yes'then st:='pending';end if;
if host and not gg.online then st:=coalesce(payload->>'verdict','pending');if st not in('yes','no','pending')then raise exception 'Неверный вердикт';end if;end if;
bon:=payload->>'bonus';if gg.kind='bonus'then if bon is null or coalesce((board->'bonuses'->>bon)::int,0)<=0 then raise exception 'Этот бонус закончился или не выбран';end if;else bon:=null;end if;
insert into public.ng_submissions(id,game_id,team_id,code,answer,example,solution,files,bonus,status)values(pid,game,tm.id,slot.code,answer,example,sol,files,bon,st);perform public.ng_issue(game,tm.id,slot.code,st);
end if;
elsif op in('review','return')then
select *into sub from public.ng_submissions where game_id=game and id=(payload->>'id')::uuid for update;if not found or sub.status='cancelled'then raise exception 'Сдача недоступна или уже отменена';end if;st:=case when op='return'then 'cancelled'else payload->>'status'end;if st is null or st not in('yes','no','pending','cancelled')then raise exception 'Неверная оценка';end if;reason:=left(coalesce(payload->>'note',''),1000);
if gg.kind='domino'and st in('pending','cancelled')then
if exists(select 1 from public.ng_leases where game_id=game and(code=sub.code and team_id<>sub.team_id or team_id=sub.team_id and code<>sub.code))then raise exception 'Карточка уже передана другой команде или команда взяла следующую. Завершите текущую карточку перед возвратом';end if;
if st='cancelled'and exists(select 1 from public.ng_submissions where game_id=game and team_id=sub.team_id and code=sub.code and status<>'cancelled'and seq>sub.seq)then raise exception 'Сначала верните последнюю попытку по этой карточке';end if;insert into public.ng_leases values(game,sub.code,sub.team_id)on conflict do nothing;end if;
update public.ng_submissions set status=st,note=reason where id=sub.id;if st<>'cancelled'then perform public.ng_issue(game,sub.team_id,sub.code,st);end if;
else raise exception 'Неизвестное действие';end if;
-- A jury return/correction may reopen an automatically finished game while time remains.
-- Explicit host finishes and expired timers always remain closed.
if op in('review','return')and gg.closed and gg.ends_at>clock_timestamp()and not exists(select 1 from public.ng_events where game_id=game and action='finish')and exists(select 1 from public.ng_teams t where t.game_id=game and not(public.ng_board(game,t.id)->>'finished')::boolean)then
update public.ng_games set closed=false where id=game;update public.ng_lifecycle set finished_at=null where game_id=game;end if;
if gg.kind<>'p52'and gg.started_at is not null and not gg.closed and not exists(select 1 from public.ng_teams t where t.game_id=game and not(public.ng_board(game,t.id)->>'finished')::boolean)then update public.ng_games set closed=true where id=game;end if;
insert into public.ng_events(game_id,action,data)values(game,op,case when op in('submit','review','return')then jsonb_build_object('id',pid,'submission',sub.id,'status',st)else '{}'end);
update public.ng_lifecycle set activity_at=now()where game_kind=gg.kind and game_id=game;
return public.ng_state(game,token);end $$;


create function public.ng_finished(g uuid)returns timestamptz language sql stable set search_path=''as $$select case when gg.closed then coalesce(l.finished_at,least(now(),coalesce(gg.ends_at,now())))when gg.ends_at<=now()then gg.ends_at end from public.ng_games gg left join public.ng_lifecycle l on l.game_id=gg.id where gg.id=g $$;
create function public.ng_public_result(g uuid)returns jsonb language sql stable set search_path=''as $$select public.ng_state(g,'')-'tasks'-'records'-'links'-'bonuses'$$;
create function public.ng_touch()returns trigger language plpgsql security definer set search_path=''as $$declare f timestamptz;begin
insert into public.ng_lifecycle(game_kind,game_id,activity_at)values(new.kind,new.id,now())on conflict(game_id)do update set activity_at=excluded.activity_at;
f:=public.ng_finished(new.id);if f is not null then update public.ng_lifecycle set finished_at=coalesce(finished_at,f)where game_id=new.id;end if;return new;end $$;
create trigger ng_activity after insert or update on public.ng_games for each row execute function public.ng_touch();
create table public.ng_game_templates(id uuid primary key default gen_random_uuid(),owner_id uuid not null references auth.users(id)on delete cascade,title text not null check(length(title)between 1 and 100),game_kind text not null check(game_kind in('p52','xo','maze','bonus','domino')),settings jsonb not null,tasks jsonb not null,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create table public.ng_template_runs(owner_id uuid references auth.users(id)on delete cascade,request_id uuid,template_id uuid references public.ng_game_templates(id)on delete set null,game_kind text not null,game_id uuid not null references public.ng_games(id)on delete cascade,host_token text not null,created_at timestamptz not null default now(),primary key(owner_id,request_id));
alter table public.ng_game_templates enable row level security;alter table public.ng_template_runs enable row level security;revoke all on public.ng_game_templates,public.ng_template_runs from public,anon,authenticated;
create function public.ng_templates(op text,payload jsonb default '{}')returns jsonb language plpgsql security definer set search_path=''as $$
#variable_conflict use_column
declare u uuid:=auth.uid();tmpl public.ng_game_templates;run public.ng_template_runs;tid uuid:=(payload->>'id')::uuid;gid uuid;host text;k text;v_title text;v_settings jsonb;rows jsonb;created jsonb;req uuid;begin
if u is null then raise exception 'Войдите в личные сценарии';end if;
if op='list'then return coalesce((select jsonb_agg(to_jsonb(x))from(select id,title,game_kind,settings,updated_at,jsonb_array_length(tasks)task_count,public.mg_task_status(tasks)task_status from public.ng_game_templates where owner_id=u order by updated_at desc limit 100)x),'[]');end if;
if op='recent'then return coalesce((select jsonb_agg(to_jsonb(x))from(select game_kind,game_id,host_token,template_id,created_at from public.ng_template_runs where owner_id=u order by created_at desc limit 20)x),'[]');end if;
if tid is not null then select *into tmpl from public.ng_game_templates where id=tid and owner_id=u for update;if not found then raise exception 'Сценарий недоступен';end if;end if;
if op='get'then if tid is null then raise exception 'Выберите сценарий';end if;return(to_jsonb(tmpl)-'owner_id')||jsonb_build_object('task_status',public.mg_task_status(tmpl.tasks));end if;
if op='delete'then if tid is null then raise exception 'Выберите сценарий';end if;delete from public.ng_game_templates where id=tid;return '{}';end if;
if op='rename'then v_title:=trim(payload->>'title');if tid is null or v_title is null or length(v_title)not between 1 and 100 then raise exception 'Название: до 100 символов';end if;update public.ng_game_templates set title=v_title,updated_at=now()where id=tid;return jsonb_build_object('id',tid);end if;
if op='save'then k:=payload->>'kind';gid:=(payload->>'game')::uuid;host:=payload->>'token';v_title:=trim(payload->>'title');if not public.ng_host(k,gid,host)then raise exception 'Нужна ссылка ведущего';end if;if v_title is null or length(v_title)not between 1 and 100 then raise exception 'Название: до 100 символов';end if;if exists(select 1 from public.ng_lifecycle where game_id=gid and archived)then raise exception 'Подробности игры уже очищены';end if;
rows:=public.ng_tasks(k,gid,host,'get')->'rows';select g.settings||jsonb_build_object('title',g.title,'minutes',g.minutes,'online',g.online,'names',(select jsonb_agg(name order by position)from public.ng_teams where game_id=gid))into v_settings from public.ng_games g where id=gid;
if tid is null then insert into public.ng_game_templates(owner_id,title,game_kind,settings,tasks)values(u,v_title,k,v_settings,rows)returning id into tid;else update public.ng_game_templates set title=v_title,game_kind=k,settings=v_settings,tasks=rows,updated_at=now()where id=tid;end if;return jsonb_build_object('id',tid,'task_status',public.mg_task_status(rows));end if;
if op='launch'then if tid is null then raise exception 'Выберите сценарий';end if;req:=(payload->>'request')::uuid;if req is null then raise exception 'Нужен идентификатор запуска';end if;perform pg_advisory_xact_lock(hashtextextended(u::text||req::text,0));select *into run from public.ng_template_runs where owner_id=u and request_id=req;if found then return jsonb_build_object('id',run.game_id,'hostToken',run.host_token,'kind',run.game_kind,'template_id',run.template_id);end if;
k:=tmpl.game_kind;created:=public.ng_api('create',null,'',tmpl.settings||jsonb_build_object('kind',k,'title',left(coalesce(nullif(trim(payload->>'title'),''),tmpl.title),100)));gid:=(created->>'id')::uuid;host:=created->>'hostToken';select coalesce(jsonb_agg(x-'bank_id'-'bank_version'),'[]')into rows from jsonb_array_elements(tmpl.tasks)x;perform public.ng_tasks(k,gid,host,'save',jsonb_build_object('rows',rows));insert into public.ng_template_runs values(u,req,tid,k,gid,host,now());return jsonb_build_object('id',gid,'hostToken',host,'kind',k,'template_id',tid);end if;raise exception 'Неизвестное действие';end $$;
create function public.ng_remove(g uuid,details_only boolean default false)returns void language plpgsql set search_path=''as $$declare k text;begin
select kind into strict k from public.ng_games where id=g;
update public.mg_files set expires_at=now()where game_kind=k and game_id=g;delete from public.ng_submissions where game_id=g;delete from public.ng_events where game_id=g;delete from public.ng_leases where game_id=g;delete from public.ng_issued where game_id=g;delete from public.ng_slots where game_id=g;delete from public.mg_task_copies where game_kind=k and game_id=g;
if details_only then update public.ng_games set closed=true where id=g;else delete from public.ng_games where id=g;end if;end $$;
create function public.ng_lifecycle_api(k text,g uuid,t text,op text)returns jsonb language plpgsql security definer set search_path=''as $$declare l public.ng_lifecycle;r jsonb;begin
if not public.ng_host(k,g,t)then raise exception 'Нужна ссылка ведущего';end if;select *into l from public.ng_lifecycle where game_id=g for update;
if op='results'then r:=coalesce(l.result,public.ng_public_result(g));return jsonb_build_object('title',r->'title','teams',(select jsonb_agg(jsonb_build_object('Команда',x->>'name','Баллы',x->'total','Отправок',x->'sent','На проверке',x->'pending'))from jsonb_array_elements(r->'teams')x));end if;
if op='delete'then if public.ng_finished(g)is null then raise exception 'Сначала завершите игру';end if;perform public.ng_remove(g,false);return '{}';end if;raise exception 'Неизвестное действие';end $$;
create function public.ng_cleanup()returns jsonb language plpgsql security definer set search_path=''as $$declare l public.ng_lifecycle;f timestamptz;removed int:=0;archived_count int:=0;begin
for l in select *from public.ng_lifecycle for update skip locked loop f:=coalesce(l.finished_at,public.ng_finished(l.game_id));if f is not null then update public.ng_lifecycle set finished_at=f where game_id=l.game_id;
if f<now()-interval '30 days'then perform public.ng_remove(l.game_id,false);removed:=removed+1;
elsif f<now()-interval '7 days'and not l.archived then update public.ng_lifecycle set result=public.ng_public_result(l.game_id),archived=true where game_id=l.game_id;perform public.ng_remove(l.game_id,true);archived_count:=archived_count+1;end if;
elsif l.activity_at<now()-interval '30 days'and exists(select 1 from public.ng_games where id=l.game_id and started_at is null)then perform public.ng_remove(l.game_id,false);removed:=removed+1;end if;end loop;
-- The existing private file cleanup already purges every expired mg_files row, including these new kinds.
return jsonb_build_object('removed',removed,'archived',archived_count);end $$;
select cron.schedule('math-games-new-retention','19 * * * *','select public.ng_cleanup();');
create function public.ng_files_access(op text,k text default '',g uuid default null,t text default '',p jsonb default '{}')returns jsonb language plpgsql security definer set search_path=''as $$
#variable_conflict use_column
declare host boolean;team uuid;row public.mg_files;fid uuid;task jsonb;requested_code text:=p->>'code';gg public.ng_games;begin
if op not in('upload','ready','get','discard')then raise exception 'Нет доступа';end if;select *into gg from public.ng_games where id=g and kind=k;if not found then raise exception 'Игра недоступна';end if;host:=public.ng_host(k,g,t);select id into team from public.ng_teams where game_id=g and token=t;if not host and(team is null or not gg.online)then raise exception 'Нет доступа';end if;
if op='upload'then
if gg.started_at is null or gg.closed or gg.ends_at<=now()or exists(select 1 from public.ng_lifecycle where game_id=g and archived)then raise exception 'Приём файлов закрыт';end if;
if host then if gg.online then raise exception 'Используйте ссылку команды';end if;team:=(p->>'team')::uuid;end if;if not exists(select 1 from public.ng_teams where game_id=g and id=team)then raise exception 'Нет команды';end if;
select content into task from public.mg_task_copies where game_kind=k and game_id=g and code=requested_code and exists(select 1 from jsonb_array_elements(public.ng_board(g,team)->'cells')x where x->>'code'=requested_code and(x->>'available')::boolean);
if task is null or task->>'attachments'='forbidden'then raise exception 'Вложения запрещены или задача недоступна';end if;
if coalesce(p->>'mime','')not in('image/jpeg','image/png','image/heic','image/heif','application/pdf')then raise exception 'Неподдерживаемый формат';end if;
if(select coalesce(sum(size),0)from public.mg_files where game_kind=k and game_id=g and team_id=team and answer_id is null and created_at>now()-interval '1 day')+(p->>'size')::int>62914560 then raise exception 'Слишком много неотправленных файлов';end if;
fid:=gen_random_uuid();insert into public.mg_files(id,game_kind,game_id,team_id,task_code,name,mime,size,path)values(fid,k,g,team,requested_code,left(coalesce(p->>'name','file'),200),p->>'mime',(p->>'size')::int,k||'/'||g||'/'||fid)returning *into row;return to_jsonb(row);end if;
select *into row from public.mg_files where id=(p->>'id')::uuid and game_kind=k and game_id=g for update;if not found or not(host or row.team_id=team)or row.expires_at is not null then raise exception 'Файл недоступен';end if;
if op='ready'then update public.mg_files set ready=true where id=row.id;return to_jsonb(row);elsif op='get'then if not row.ready then raise exception 'Файл не загружен';end if;return to_jsonb(row);else if row.answer_id is not null then raise exception 'Отправленное вложение нельзя удалить отдельно';end if;update public.mg_files set expires_at=now()where id=row.id;return to_jsonb(row);end if;end $$;
revoke all on function public.ng_host(text,uuid,text),public.ng_setup(uuid),public.ng_board(uuid,uuid),public.ng_issue(uuid,uuid,text,text),public.ng_finished(uuid),public.ng_public_result(uuid),public.ng_touch(),public.ng_remove(uuid,boolean),public.ng_cleanup(),public.ng_templates(text,jsonb),public.ng_state(uuid,text),public.ng_tasks(text,uuid,text,text,jsonb),public.ng_api(text,uuid,text,jsonb),public.ng_lifecycle_api(text,uuid,text,text),public.ng_files_access(text,text,uuid,text,jsonb)from public,anon,authenticated;
grant execute on function public.ng_state(uuid,text),public.ng_tasks(text,uuid,text,text,jsonb),public.ng_api(text,uuid,text,jsonb),public.ng_lifecycle_api(text,uuid,text,text)to anon,authenticated;
grant execute on function public.ng_templates(text,jsonb)to authenticated;grant execute on function public.ng_files_access(text,text,uuid,text,jsonb)to service_role;
commit;
