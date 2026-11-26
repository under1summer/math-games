-- Fixture-only regression. All accounts, scenarios and games roll back.
begin;
do $$declare u uuid:=gen_random_uuid();created jsonb;gid uuid;h text;rows jsonb;t jsonb;run jsonb;state jsonb;cfg jsonb:='{"width":2,"height":2,"cells":[[0,0],[1,0],[0,1],[1,1]],"parts":2,"rule":"congruent"}';begin
assert public.mg_task_status('[]')->>'total'='0';
assert public.mg_task_status('[{"code":"1","content":{"condition":"","mode":"manual"}}]')->>'ready'='0';
assert public.mg_task_status('[{"code":"1","content":{"condition":"Question","mode":"number","key":""}}]')->'missing'->0->>'reason'='Нет ключа проверки';
insert into auth.users(id,email)values(u,u||'@example.invalid');perform set_config('request.jwt.claim.sub',u::text,true);
created:=public.ab_api('create');gid:=(created->>'id')::uuid;h:=created->>'hostToken';perform public.ab_api('configure',gid,h,'{"themes":3,"tasks":4,"minutes":75,"names":["A","B","C","D","E","F"]}');
t:=public.mg_templates('save',jsonb_build_object('kind','ab','game',gid,'token',h,'title','Empty fixture'));
assert t->'task_status'->>'total'='12'and t->'task_status'->>'filled'='0'and t->'task_status'->>'ready'='0';
assert public.mg_templates('list')->0->'task_status'->>'ready'='0';
rows:=public.mg_tasks('ab',gid,h,'get')->'rows';select jsonb_agg(x||jsonb_build_object('content',jsonb_build_object('condition','Fixture: cut into two congruent parts','mode','manual','key','','kind','cutting','module_config',cfg)))into rows from jsonb_array_elements(rows)x;perform public.mg_tasks('ab',gid,h,'save',jsonb_build_object('rows',rows));
t:=public.mg_templates('save',jsonb_build_object('id',t->>'id','kind','ab','game',gid,'token',h,'title','Filled fixture'));
assert t->'task_status'->>'filled'='12'and t->'task_status'->>'ready'='12';assert public.mg_templates('get',jsonb_build_object('id',t->>'id'))->'tasks'->0->'content'->'module_config'=cfg;
run:=public.mg_templates('launch',jsonb_build_object('id',t->>'id','request',gen_random_uuid()));state:=public.ab_api('start',(run->>'id')::uuid,run->>'hostToken');assert(state->>'start')::bigint>0;assert jsonb_array_length(state->'taskInfo')=12;
state:=public.ab_api('state',(run->>'id')::uuid,state->'links'->0->>'token');assert not(state->'taskInfo'->0?'key');
assert not has_function_privilege('anon','public.mg_task_status(jsonb)','EXECUTE');
end $$;
select 'PASS: 12 empty slots = 0 tasks; missing keys identified; 12 interactive snapshots survive launch and abaka starts without text keys; answers private' as result;
rollback;
