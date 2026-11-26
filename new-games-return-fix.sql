-- Update only the new-game engine. Existing games are unchanged.
begin;
create or replace function public.ng_api(op text,game uuid default null,token text default '',payload jsonb default '{}')returns jsonb language plpgsql security definer set search_path=''as $$
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
if gg.started_at is not null then raise exception 'Игра уже запускалась';end if;if exists(select 1 from public.ng_slots s left join public.mg_task_copies c on c.game_kind=gg.kind and c.game_id=game and c.code=s.code where s.game_id=game and(nullif(trim(c.content->>'condition'),'')is null or(c.content->>'kind'<>'cutting'and c.content->>'mode'<>'manual'and nullif(trim(c.content->>'key'),'')is null)))then raise exception 'Заполните и сохраните все условия и ключи';end if;
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


commit;
