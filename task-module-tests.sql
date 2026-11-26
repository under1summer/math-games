-- Owner-only regression suite. All fixtures, bank accounts and cleanup effects ROLLBACK.
begin;
create function pg_temp.must_reject(k text,g uuid,t text,op text,p jsonb default '{}')returns void language plpgsql as $$begin begin perform public.mg_tasks(k,g,t,op,p);exception when others then return;end;raise exception 'Expected access rejection';end $$;
do $$
declare cfg jsonb:='{"width":3,"height":2,"cells":[[0,0],[1,0],[2,0],[0,1],[1,1],[2,1]],"parts":2,"rule":"congruent"}';sol jsonb:='{"cuts":["0,0|0,1","1,0|1,1","2,0|2,1"]}';c jsonb;s jsonb;r jsonb;rows jsonb;g uuid;h text;tt text;target uuid;sid uuid;k text;u uuid:=gen_random_uuid();other_u uuid:=gen_random_uuid();bank jsonb;bank_id uuid;oldc jsonb;f timestamptz;before_count bigint;after_count bigint;
begin
assert public.mg_cut_check(cfg,null)='valid';assert public.mg_cut_check(cfg,sol)='yes';assert public.mg_cut_check(cfg,'{"cuts":[]}')='no';assert public.mg_cut_check(cfg||'{"rule":"equal_area"}',sol)='yes';assert public.mg_cut_check(cfg||'{"rule":"distinct"}',sol)='no';assert public.mg_cut_check(cfg||'{"rule":"manual"}',sol)='pending';
assert public.mg_cut_shape(array['0,0','1,0','1,1'])=public.mg_cut_shape(array['3,3','3,4','2,4']);
begin perform public.mg_cut_check('{"width":2,"height":2,"cells":[[0,0],[1,1]],"parts":2,"rule":"manual"}',null);raise check_violation;exception when raise_exception then null;end;
begin perform public.mg_cut_check(cfg,'{"cuts":["0,0|2,0"]}');raise check_violation;exception when raise_exception then null;end;
insert into auth.users(id,email)values(u,u||'@example.invalid'),(other_u,other_u||'@example.invalid');perform set_config('request.jwt.claim.sub',u::text,true);
c:=public.mg_validate(jsonb_build_object('title','Test bank','condition','Разрежьте $3\\times2$','mode','manual','key','','kind','cutting','module_config',cfg));
bank:=public.mg_bank('save',jsonb_build_object('content',c));bank_id:=(bank->>'id')::uuid;assert bank->>'version'='1';r:=public.mg_bank('save',jsonb_build_object('content',c));assert(r->>'duplicate')::boolean;assert r->>'id'=bank_id::text;
for k in select unnest(array['od','ab','ps','birzha'])loop
case k when 'od'then r:=public.od_api('create');g:=(r->>'game')::uuid;h:=r->>'host';perform public.od_api('configure',g,h,'{"names":["A","B","C"]}');
when 'ab'then r:=public.ab_api('create');g:=(r->>'id')::uuid;h:=r->>'hostToken';perform public.ab_api('configure',g,h,'{"names":["A","B"],"themes":1,"tasks":2,"minutes":30}');
when 'ps'then r:=public.ps_api('create');g:=(r->>'id')::uuid;h:=r->>'hostToken';perform public.ps_api('configure',g,h,'{"names":["A","B"],"rounds":1,"interval":30}');
else r:=public.mg_tasks(k,null,'','create');g:=(r->>'id')::uuid;h:=r->>'hostToken';end case;
perform pg_temp.must_reject(k,g,'','get');perform pg_temp.must_reject(k,g,'forged','get');
s:=public.mg_tasks(k,g,h,'get');if k='birzha'then rows:=jsonb_build_array(jsonb_build_object('code','1','content',c,'bank_id',bank_id,'bank_version',1));else select jsonb_agg(x||jsonb_build_object('content',c,'bank_id',bank_id,'bank_version',1))into rows from jsonb_array_elements(s->'rows')x;end if;
s:=public.mg_tasks(k,g,h,'save',jsonb_build_object('rows',rows));assert jsonb_array_length(s->'rows')=jsonb_array_length(rows);assert s->'rows'->0->'content'->>'title'='Test bank';
-- Re-saving imported bank versions must not create bank duplicates or change their version.
perform public.mg_tasks(k,g,h,'save',jsonb_build_object('rows',s->'rows'));assert(select count(*)from public.mg_bank_tasks where owner_id=u)=1;
if k='od'then s:=public.od_api('start',g,h);tt:=s->'links'->0->>'token';sid:=gen_random_uuid();r:=public.od_api('submit',g,tt,jsonb_build_object('id',sid,'answers',jsonb_build_array(jsonb_build_object('n',1,'text','','solution',sol))));s:=public.od_api('state',g,tt);assert s->'packets'->0->'answers'->0->>'status'='yes';assert not(s->'tasks'->0?'key');assert not(s?'links');perform public.od_api('close',g,h);
elsif k='ab'then s:=public.ab_api('start',g,h);tt:=s->'links'->0->>'token';sid:=gen_random_uuid();r:=public.ab_api('submit',g,tt,jsonb_build_object('id',sid,'theme',1,'n',1,'answer','','solution',sol));assert r->>'status'='yes';s:=public.ab_api('state',g,tt);assert s->'records'->0->'solution'=sol;assert not(s->'taskInfo'->0?'key');perform public.ab_api('close',g,h);
elsif k='ps'then s:=public.ps_api('start',g,h);tt:=s->'links'->0->>'token';target:=(s->'teams'->1->>'id')::uuid;sid:=gen_random_uuid();s:=public.ps_api('submit',g,tt,jsonb_build_object('id',sid,'task','m:1','answer','','solution',sol));assert s->'submissions'->0->>'status'='JUDGED';assert(s->'submissions'->0->>'correct')::boolean;assert not(s->'tasks'->0?'key');perform public.ps_api('judge',g,h,jsonb_build_object('submission',sid,'correct',false));s:=public.ps_api('state',g,h);assert not(s->'submissions'->0->>'correct')::boolean;perform public.ps_api('finish',g,h);end if;
if k<>'birzha'then
perform pg_temp.must_reject(k,g,h,'save',jsonb_build_object('rows',rows));
r:=public.mg_lifecycle_api(k,g,h,'results');assert jsonb_array_length(r->'teams')>0;
-- Only this transaction's games are aged. Existing production games remain protected.
update public.mg_lifecycle set finished_at=now()-interval '8 days'where game_kind=k and game_id=g;perform public.mg_cleanup();assert(select archived from public.mg_lifecycle where game_kind=k and game_id=g);r:=public.mg_lifecycle_api(k,g,h,'results');assert jsonb_array_length(r->'teams')>0;
case k when 'od'then assert not exists(select 1 from public.od_packets where game_id=g);s:=public.od_api('state',g,tt);when 'ab'then assert not exists(select 1 from public.ab_submissions where game_id=g);s:=public.ab_api('state',g,tt);else assert not exists(select 1 from public.ps_submissions where game_id=g);s:=public.ps_api('state',g,tt);end case;assert(s->>'archived')::boolean;
update public.mg_lifecycle set finished_at=now()-interval '31 days'where game_kind=k and game_id=g;perform public.mg_cleanup();assert not exists(select 1 from public.mg_lifecycle where game_kind=k and game_id=g);
else update public.mg_lifecycle set activity_at=now()-interval '31 days'where game_kind=k and game_id=g;perform public.mg_cleanup();assert not exists(select 1 from public.mg_workbenches where id=g);end if;
end loop;
oldc:=c;c:=c||'{"condition":"Updated bank condition"}';r:=public.mg_bank('save',jsonb_build_object('id',bank_id,'content',c));assert r->>'version'='2';assert(select content from public.mg_bank_versions where task_id=bank_id and version=1)=oldc;
perform set_config('request.jwt.claim.sub',other_u::text,true);r:=public.mg_bank('search');assert jsonb_array_length(r)=0;begin perform public.mg_bank('delete',jsonb_build_object('id',bank_id));raise check_violation;exception when raise_exception then null;end;
perform set_config('request.jwt.claim.sub',u::text,true);perform public.mg_bank('delete',jsonb_build_object('id',bank_id));assert not exists(select 1 from public.mg_bank_versions where task_id=bank_id);
assert exists(select 1 from cron.job where jobname='math-games-retention'and active);
assert not has_table_privilege('anon','public.mg_bank_versions','SELECT');assert not has_table_privilege('authenticated','public.mg_task_copies','SELECT');assert not has_function_privilege('anon','public.mg_cleanup()','EXECUTE');
end $$;
select 'PASS: 4 task adapters, bank isolation/dedup/versioning, interactive grading, manual recheck, retention, cron and access control' as result;
rollback;
