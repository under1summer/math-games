begin;
do $$
declare k text;r jsonb;s jsonb;g uuid;h text;t uuid;pid uuid;blocked boolean;begin
foreach k in array array['iv','p52','xo','maze','bonus','domino']loop
r:=public.ng_api('create',null,'',jsonb_build_object('kind',k,'names','["QA A","QA B"]'::jsonb,'online',false));g:=(r->>'id')::uuid;h:=r->>'hostToken';
assert not exists(select 1 from public.mg_task_copies where game_id=g and nullif(trim(content->>'condition'),'')is not null),'fixture has no conditions';
s:=public.ng_api('start',g,h);assert s->>'start'is not null,'paper starts without content';
end loop;
r:=public.iv_api('create',null,'','{"names":["QA A","QA B"]}');g:=(r->>'id')::uuid;h:=r->>'hostToken';blocked:=false;
begin perform public.iv_api('start',g,h);exception when others then blocked:=true;end;assert blocked,'online still needs conditions';
perform public.iv_api('delivery',g,h,'{"online":false}');s:=public.iv_api('start',g,h);assert s->>'start'is not null;t:=(s->'teams'->0->>'id')::uuid;
pid:=gen_random_uuid();perform public.iv_api('submit',g,h,jsonb_build_object('id',pid,'team',t,'code','1','answer','Сдано на листочке','verdict','yes'));
assert(select status='yes' from public.ng_submissions where id=pid),'paper jury verdict';assert jsonb_array_length(public.iv_state(g,h)->'stocks'->t::text)=1,'paper answer enters reserve';
blocked:=false;begin perform public.iv_api('delivery',g,h,'{"online":true}');exception when others then blocked:=true;end;assert blocked,'delivery locked after start';
r:=public.ab_api('create',null,'','{}');g:=(r->>'id')::uuid;h:=r->>'hostToken';perform public.ab_api('delivery',g,h,'{"online":false}');perform public.ab_api('start',g,h);assert(select start_ms is not null from public.ab_games where id=g),'abaka paper starts';
end $$;
rollback;
select 'PASS: paper starts with no uploaded tasks; online and mode locks preserved; jury reserve works' as result;
