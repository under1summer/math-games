-- Regression tests: rolled back; creates no permanent game or submissions.
begin;
do $$
begin
 assert public.od_score('[{"status":"yes"},{"status":"yes"}]')=6,'2/2 = 6';
 assert public.od_score('[{"status":"no"},{"status":"no"},{"status":"no"}]')=-1,'0/3 = -1';
 assert public.od_score('[{"status":"yes"},{"status":"pending"}]') is null,'pending';
 assert public.od_normal('Ответ: (10 минут и 15 минут)','set')='10;15','set parser';
 assert public.od_normal('55 345 123 451 234 5','number') is null,'reject malformed grouping';
 assert public.od_normal('553451234512345','number')='553451234512345','large exact integer';
end $$;
set local role anon;
do $$
declare r jsonb; g uuid; h text; t text; t2 text; p uuid:=gen_random_uuid(); q uuid:=gen_random_uuid(); s jsonb; b boolean; tasks jsonb;
begin
 r:=public.od_api('create',null,'','{"title":"ТЕСТ — откат"}');g:=(r->>'game')::uuid;h:=r->>'host';
 select jsonb_agg(jsonb_build_object('n',n,'title','Тест '||n,'mode',case when n=4 then 'manual' when n=13 then 'set' when n=1 then 'text' else 'number' end,'key',case when n=13 then '12;14' when n=1 then 'МПИР' else '105' end)) into tasks from generate_series(1,24) n;
 r:=public.od_api('tasks',g,h,jsonb_build_object('tasks',tasks));
 r:=public.od_api('configure',g,h,'{"names":["Альфа","Бета","Гамма"]}');t:=r->'links'->0->>'token';t2:=r->'links'->1->>'token';
 b:=false;begin perform public.od_api('submit',g,t,jsonb_build_object('id',p,'answers','[{"n":2,"text":"105"}]'::jsonb));exception when others then b:=true;end;assert b,'before start rejected';
 r:=public.od_api('state',g,'');assert not(r?'tasks') and not(r?'packets') and not(r?'links'),'public privacy';
 r:=public.od_api('state',g,t);assert not(r->'tasks'->0?'key'),'team cannot read keys';
 b:=false;begin perform public.od_api('start',g,t);exception when others then b:=true;end;assert b,'team cannot start';
 b:=false;begin perform count(*) from public.od_games;exception when insufficient_privilege then b:=true;end;assert b,'direct tables denied';
 r:=public.od_api('start',g,h);assert r->>'start' is not null,'started';
 r:=public.od_api('submit',g,t,jsonb_build_object('id',p,'answers','[{"n":2,"text":"105"},{"n":3,"text":"105"}]'::jsonb));
 r:=public.od_api('submit',g,t,jsonb_build_object('id',p,'answers','[{"n":2,"text":"105"}]'::jsonb));
 r:=public.od_api('state',g,t);assert jsonb_array_length(r->'packets')=1,'retry idempotency';assert (r->'packets'->0->>'score')::int=6,'automatic packet score';
 b:=false;begin perform public.od_api('submit',g,t,jsonb_build_object('id',q,'answers','[{"n":2,"text":"105"}]'::jsonb));exception when others then b:=true;end;assert b,'duplicate task rejected';
 b:=false;begin perform public.od_api('submit',g,t,jsonb_build_object('id',q,'answers','[{"text":"105"}]'::jsonb));exception when others then b:=true;end;assert b,'missing task rejected';
 r:=public.od_api('submit',g,t,jsonb_build_object('id',q,'answers','[{"n":4,"text":"на фото"}]'::jsonb,'image','data:image/jpeg;base64,/9j/2Q=='));
 r:=public.od_api('state',g,t);assert (r->'packets'->1->>'score') is null,'manual pending';
 r:=public.od_api('state',g,t2);assert jsonb_array_length(r->'packets')=0,'other submissions hidden';
 b:=false;begin perform public.od_api('photo',g,t2,jsonb_build_object('id',q));exception when others then b:=true;end;assert b,'other photos hidden';
 r:=public.od_api('photo',g,h,jsonb_build_object('id',q));assert r->>'image'='data:image/jpeg;base64,/9j/2Q==','photo retained';
 b:=false;begin perform public.od_api('judge',g,t,jsonb_build_object('id',q,'n',4,'status','yes'));exception when others then b:=true;end;assert b,'team cannot judge';
 r:=public.od_api('judge',g,h,jsonb_build_object('id',q,'n',4,'status','yes'));assert (r->'packets'->1->>'score')::int=2,'manual judge';
 r:=public.od_api('judge',g,h,jsonb_build_object('id',p,'n',3,'status','no'));assert (r->'packets'->0->>'score')::int=1,'rejudge score';
 r:=public.od_api('cancel',g,h,jsonb_build_object('id',p,'n',3));assert (r->'packets'->0->>'score')::int=2,'cancel recomputes size';
 r:=public.od_api('submit',g,t,jsonb_build_object('id',gen_random_uuid(),'answers','[{"n":3,"text":"105"}]'::jsonb));
 r:=public.od_api('close',g,h);
 b:=false;begin perform public.od_api('submit',g,t,jsonb_build_object('id',gen_random_uuid(),'answers','[{"n":5,"text":"105"}]'::jsonb));exception when others then b:=true;end;assert b,'closed blocks submits';
 r:=public.od_api('judge',g,h,jsonb_build_object('id',q,'n',4,'status','no'));assert (r->'packets'->1->>'score')::int=0,'judge after close';
end $$;
rollback;
select 'PASS: scoring, parsing, permissions, privacy, photos, idempotency, duplicate protection, manual checks, cancellation, close' as result;
