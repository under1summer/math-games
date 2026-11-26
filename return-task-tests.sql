-- Transactional regression: wrong interactive answer -> host return -> new correct attempt.
begin;
do $$declare k text;r jsonb;s jsonb;g uuid;h text;tt text;rows jsonb;pid uuid;again uuid;event bigint;denied boolean;cfg jsonb:='{"width":3,"height":2,"cells":[[0,0],[1,0],[2,0],[0,1],[1,1],[2,1]],"parts":2,"rule":"congruent"}';good jsonb:='{"cuts":["0,0|0,1","1,0|1,1","2,0|2,1"]}';content jsonb;begin
content:=public.mg_validate(jsonb_build_object('condition','Fixture: cut into two congruent parts','kind','cutting','mode','manual','key','','module_config',cfg));
foreach k in array array['od','ab','ps']loop
case k when 'od'then r:=public.od_api('create');g:=(r->>'game')::uuid;h:=r->>'host';perform public.od_api('configure',g,h,'{"names":["A","B","C"]}');
when 'ab'then r:=public.ab_api('create');g:=(r->>'id')::uuid;h:=r->>'hostToken';perform public.ab_api('configure',g,h,'{"names":["A","B"],"themes":1,"tasks":1,"minutes":30}');
when 'ps'then r:=public.ps_api('create');g:=(r->>'id')::uuid;h:=r->>'hostToken';perform public.ps_api('configure',g,h,'{"names":["A","B"],"rounds":1,"interval":30}');end case;
rows:=public.mg_tasks(k,g,h,'get')->'rows';select jsonb_agg(x||jsonb_build_object('content',content))into rows from jsonb_array_elements(rows)x;perform public.mg_tasks(k,g,h,'save',jsonb_build_object('rows',rows));pid:=gen_random_uuid();again:=gen_random_uuid();
case k when 'od'then s:=public.od_api('start',g,h);tt:=s->'links'->0->>'token';perform public.od_api('submit',g,tt,jsonb_build_object('id',pid,'answers',jsonb_build_array(jsonb_build_object('n',1,'solution','{"cuts":[]}'::jsonb))));assert(select answers->0->>'status'='no'from public.od_packets where id=pid);
denied:=false;begin perform public.od_api('cancel',g,tt,jsonb_build_object('id',pid,'n',1));exception when others then denied:=true;end;assert denied;
perform public.od_api('cancel',g,h,jsonb_build_object('id',pid,'n',1));assert(select(answers->0->>'cancelled')::boolean from public.od_packets where id=pid);
perform public.od_api('submit',g,tt,jsonb_build_object('id',again,'answers',jsonb_build_array(jsonb_build_object('n',1,'solution',good))));assert(select answers->0->>'status'='yes'and public.od_score(answers)>0 from public.od_packets where id=again);
when 'ab'then s:=public.ab_api('start',g,h);tt:=s->'links'->0->>'token';r:=public.ab_api('submit',g,tt,jsonb_build_object('id',pid,'theme',1,'n',1,'solution','{"cuts":[]}'::jsonb));assert r->>'status'='no';
denied:=false;begin perform public.ab_api('review',g,tt,jsonb_build_object('id',pid,'status','cancelled'));exception when others then denied:=true;end;assert denied;
perform public.ab_api('review',g,h,jsonb_build_object('id',pid,'status','cancelled','note','Return fixture'));assert(select status='cancelled'from public.ab_submissions where id=pid);
r:=public.ab_api('submit',g,tt,jsonb_build_object('id',again,'theme',1,'n',1,'solution',good));assert r->>'status'='yes';assert(select count(*)=1 from public.ab_submissions where game_id=g and status<>'cancelled');assert(public.ab_calculate(g)->'teams'->0->>'total')::int>0;
when 'ps'then s:=public.ps_api('start',g,h);tt:=s->'links'->0->>'token';perform public.ps_api('submit',g,tt,jsonb_build_object('id',pid,'task','m:1','solution','{"cuts":[]}'::jsonb));select event_id into event from public.ps_submissions where id=pid;assert event is not null;assert(select not correct from public.ps_submissions where id=pid);
denied:=false;begin perform public.ps_api('cancel',g,tt,jsonb_build_object('id',gen_random_uuid(),'event',event,'reason','forged'));exception when others then denied:=true;end;assert denied;
perform public.ps_api('cancel',g,h,jsonb_build_object('id',gen_random_uuid(),'event',event,'reason','Return fixture'));assert(select status='CANCELLED'from public.ps_submissions where id=pid);assert(select cancelled from public.ps_events where id=event);
perform public.ps_api('submit',g,tt,jsonb_build_object('id',again,'task','m:1','solution',good));assert(select status='JUDGED'and correct from public.ps_submissions where id=again);
end case;
end loop;
end $$;
select 'PASS: OD/Abaka/Perestrelka: wrong interactive submission cancelled by host, student can resubmit correctly; previous submission retained; scoring updated; team cannot cancel itself' result;
rollback;
