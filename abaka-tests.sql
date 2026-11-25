-- Run after abaka-schema.sql. Everything is rolled back; real games are untouched.
begin;
select set_config('ab.test_od',md5((select coalesce(jsonb_agg(to_jsonb(og) order by og.id)::text,'') from public.od_games og)||(select coalesce(jsonb_agg(to_jsonb(ot) order by ot.id)::text,'') from public.od_teams ot)||(select coalesce(jsonb_agg(to_jsonb(op) order by op.id)::text,'') from public.od_packets op)),true);
do $$ begin
 assert public.ab_number('1/2')=public.ab_number('0,5'),'fractions';
 assert public.ab_number('1/0') is null and public.ab_number('2+3') is null,'no expression guessing';
 assert public.ab_number('9007199254740992') is null,'unsafe integer';
 assert public.ab_normal('14; 12','Набор чисел')=public.ab_normal('12;14','Набор чисел'),'sets';
 assert public.ab_normal('1;1;2','Набор чисел')<>public.ab_normal('1;2','Набор чисел'),'multiplicity';
 assert public.ab_normal('  ЁЛКА   А ','Текст')='елка а','text normalization';
end $$;
set local role anon;
do $$
declare r jsonb; g uuid; h text; t text; t2 text; p uuid:=gen_random_uuid(); q uuid:=gen_random_uuid(); z uuid; b boolean; k text; tasks jsonb; a int; n int; tbl text;
begin
 foreach tbl in array array['ab_games','ab_teams','ab_tasks','ab_submissions','ab_photos','ab_events'] loop
  b:=false;begin execute 'select count(*) from public.'||quote_ident(tbl);exception when insufficient_privilege then b:=true;end;assert b,'direct access denied: '||tbl;
 end loop;
 r:=public.ab_api('create',null,'','{"title":"AB regression fixture"}');g:=(r->>'id')::uuid;h:=r->>'hostToken';
 perform set_config('ab.test_game',g::text,true);perform set_config('ab.test_host',h,true);
 b:=false;begin perform public.ab_api('start',g,h);exception when others then b:=SQLERRM='Заполните и сохраните все условия и ключи';end;assert b,'empty tasks block start';
 r:=public.ab_api('configure',g,h,'{"themes":2,"tasks":2,"minutes":1,"names":["A","B"]}');t:=r->'links'->0->>'token';t2:=r->'links'->1->>'token';
 perform set_config('ab.test_team',t,true);perform set_config('ab.test_team2',t2,true);
 b:=false;begin perform public.ab_api('configure',g,h,'{"themes":13,"tasks":2,"minutes":1,"names":["A","B"]}');exception when others then b:=true;end;assert b,'bounds';
 select jsonb_agg(jsonb_build_object('theme',aa.a,'n',bb.n,'topic','Тема '||aa.a,'text','Тестовое условие','mode',case when aa.a=2 and bb.n=2 then 'Вручную' when aa.a=1 and bb.n=2 then 'Набор чисел' else 'Число' end,'key',case when aa.a=1 and bb.n=1 then '1/2' when aa.a=1 and bb.n=2 then '12;14' else '5' end)) into tasks from generate_series(1,2) aa(a) cross join generate_series(1,2) bb(n);
 r:=public.ab_api('tasks',g,h,jsonb_build_object('tasks',tasks));
 r:=public.ab_api('state',g,t);assert jsonb_array_length(r->'taskInfo')=0,'statements hidden before start';
 r:=public.ab_api('state',g,'');assert not(r?'records') and not(r?'draftTasks') and not(r?'taskInfo') and not(r?'links'),'public privacy';
 b:=false;begin perform public.ab_api('start',g,t);exception when others then b:=SQLERRM='Нет доступа ведущего';end;assert b,'no team control';
 b:=false;begin perform public.ab_api('state',g,'forged-token');exception when others then b:=true;end;assert b,'forged link';
 r:=public.ab_api('start',g,h);
 r:=public.ab_api('state',g,t);assert not(r->'taskInfo'->0?'key') and not(r?'draftTasks'),'keys hidden';
 b:=false;begin perform public.ab_api('tasks',g,h,jsonb_build_object('tasks',tasks));exception when others then b:=true;end;assert b,'frozen keys';
 b:=false;begin perform public.ab_api('submit',g,t,jsonb_build_object('id',p,'theme',1,'n',2,'answer','12;14'));exception when others then b:=SQLERRM='Сначала отправьте предыдущие задачи этой темы';end;assert b,'ordered submissions';
 r:=public.ab_api('submit',g,t,jsonb_build_object('id',p,'theme',1,'n',1,'answer','0,5'));assert r->>'status'='yes','automatic fraction';
 r:=public.ab_api('submit',g,t,jsonb_build_object('id',p,'theme',1,'n',1,'answer','wrong'));assert r->>'status'='yes','idempotent retry';
 b:=false;begin perform public.ab_api('submit',g,t,jsonb_build_object('id',gen_random_uuid(),'theme',1,'n',1,'answer','0,5'));exception when others then b:=true;end;assert b,'single attempt';
 r:=public.ab_api('submit',g,t,jsonb_build_object('id',gen_random_uuid(),'theme',1,'n',2,'answer','14;12'));assert r->>'status'='yes','automatic set';
 r:=public.ab_api('submit',g,t,jsonb_build_object('id',gen_random_uuid(),'theme',2,'n',1,'answer','5'));
 r:=public.ab_api('submit',g,t,jsonb_build_object('id',q,'theme',2,'n',2,'answer','Фото','file',jsonb_build_object('type','image/jpeg','data','/9j/AAAAAAAAAAAA')));assert r->>'status'='pending','photo always manual';
 r:=public.ab_api('picture',g,h,jsonb_build_object('id',q));assert r->>'type'='image/jpeg','photo retained';
 b:=false;begin perform public.ab_api('picture',g,t2,jsonb_build_object('id',q));exception when others then b:=true;end;assert b,'other photos denied';
 b:=false;begin perform public.ab_api('picture',g,'',jsonb_build_object('id',q));exception when others then b:=true;end;assert b,'public photos denied';
 b:=false;begin perform public.ab_api('review',g,t,jsonb_build_object('id',q,'status','yes'));exception when others then b:=true;end;assert b,'no self-judging';
 r:=public.ab_api('state',g,t2);assert jsonb_array_length(r->'records')=0,'other answers hidden';
 r:=public.ab_api('review',g,h,jsonb_build_object('id',q,'status','yes','note','Комментарий'));assert (r->'teams'->0->>'total')::int=200,'first full board: 60 base + 140 bonus';
 perform set_config('ab.test_photo',q::text,true);
 for a in 1..2 loop for n in 1..2 loop
  z:=gen_random_uuid();r:=public.ab_api('submit',g,t2,jsonb_build_object('id',z,'theme',a,'n',n,'answer',case when a=1 and n=1 then '1/2' when a=1 and n=2 then '12;14' else '5' end));
  if a=2 and n=2 then r:=public.ab_api('review',g,h,jsonb_build_object('id',z,'status','yes'));end if;
 end loop;end loop;
end $$;
reset role;
do $$
declare g uuid:=current_setting('ab.test_game')::uuid; h text:=current_setting('ab.test_host');t text:=current_setting('ab.test_team');r jsonb; target uuid;old_count int;fresh jsonb;blocked boolean;
begin
 update public.ab_submissions s set received_ms=(select position*1000 from public.ab_teams where id=s.team_id)+s.theme*10+s.n where game_id=g;
 r:=public.ab_api('state',g,h);assert (r->'teams'->0->>'total')::int=200 and (r->'teams'->1->>'total')::int=130,'first and later finishers';
 update public.ab_submissions set received_ms=5000 where game_id=g;
 r:=public.ab_api('state',g,h);assert (r->'teams'->0->>'total')::int=200 and (r->'teams'->1->>'total')::int=200 and (r->'teams'->1->>'place')::int=1,'shared first at same millisecond';
 select s.id into target from public.ab_submissions s join public.ab_teams t on t.id=s.team_id where s.game_id=g and t.position=1 and s.theme=1 and s.n=2;
 r:=public.ab_api('review',g,h,jsonb_build_object('id',target,'status','cancelled','note','Неверный номер'));assert (r->'teams'->1->>'total')::int=100,'cancellation recomputes bonuses';
 r:=public.ab_api('submit',g,t,jsonb_build_object('id',gen_random_uuid(),'theme',1,'n',2,'answer','12;14'));assert r->>'status'='yes','resubmit cancelled task';
 blocked:=false;begin perform public.ab_api('review',g,h,jsonb_build_object('id',target,'status','yes'));exception when others then blocked:=true;end;assert blocked,'cancelled history immutable';
 r:=public.ab_api('close',g,h);
 blocked:=false;begin perform public.ab_api('submit',g,t,jsonb_build_object('id',gen_random_uuid(),'theme',1,'n',1,'answer','1/2'));exception when others then blocked:=SQLERRM='Приём ответов закрыт';end;assert blocked,'closed gate';
 r:=public.ab_api('review',g,h,jsonb_build_object('id',current_setting('ab.test_photo')::uuid,'status','no','note','Исправлено после окончания'));assert r->'records' is not null,'review after close';
 select count(*) into old_count from public.ab_submissions where game_id=g;
 fresh:=public.ab_api('new',g,h);assert (fresh->>'id')::uuid<>g,'new game identity';
 r:=public.ab_api('state',(fresh->>'id')::uuid,fresh->>'hostToken');assert jsonb_array_length(r->'records')=0 and jsonb_array_length(r->'draftTasks')=4,'new clean game with copied tasks';assert r->'links'->0->>'token'<>t,'new team capability';
 assert old_count=(select count(*) from public.ab_submissions where game_id=g),'archive preserved';
 g:=(fresh->>'id')::uuid;h:=fresh->>'hostToken';t:=r->'links'->0->>'token';
 r:=public.ab_api('start',g,h);update public.ab_games set end_ms=floor(extract(epoch from clock_timestamp())*1000)-1 where id=g;
 blocked:=false;begin perform public.ab_api('submit',g,t,jsonb_build_object('id',gen_random_uuid(),'theme',1,'n',1,'answer','1/2'));exception when others then blocked:=SQLERRM='Приём ответов закрыт';end;assert blocked,'server deadline';
 assert current_setting('ab.test_od')=md5((select coalesce(jsonb_agg(to_jsonb(og) order by og.id)::text,'') from public.od_games og)||(select coalesce(jsonb_agg(to_jsonb(ot) order by ot.id)::text,'') from public.od_teams ot)||(select coalesce(jsonb_agg(to_jsonb(op) order by op.id)::text,'') from public.od_packets op)),'Optom unchanged';
end $$;
rollback;
select 'PASS: access, frozen keys, ordered attempts, idempotency, photos, scoring, first bonuses, ties, cancellation, archive, deadline; Optom unchanged' as result;
