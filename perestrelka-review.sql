-- Host recheck for legacy manual answers. Existing team-submitted answers use ps_decide.
begin;
create or replace function public.ps_review_event(p_game uuid,p_token text,p_event bigint,p_correct boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare g public.ps_games;e public.ps_events;q public.ps_submissions;t public.ps_tasks;r numeric;
begin
 select * into g from public.ps_games where id=p_game for update;
 if not found or coalesce(length(p_token),0)=0 or sha256(convert_to(p_token,'UTF8'))<>g.host_hash then raise exception 'Нет доступа ведущего';end if;
 if p_correct is null then raise exception 'Укажите вердикт';end if;
 select * into e from public.ps_events where id=p_event and game_id=p_game and kind='answer' and not cancelled for update;
 if not found then raise exception 'Ответ не найден или отменён';end if;
 select * into q from public.ps_submissions where event_id=e.id and game_id=p_game;
 if found then perform public.ps_decide(q.id,p_correct,'manual');
 else
  select * into t from public.ps_tasks where game_id=p_game and code=e.data->>'task';
  r:=(e.data->>'roll')::numeric;
  if p_correct and t.task_type='shot' and r is null then r:=random();end if;
  if (e.data->>'correct')::boolean is distinct from p_correct then
   update public.ps_events set data=data||jsonb_build_object('correct',p_correct,'roll',r) where id=e.id;
   insert into public.ps_events(request_id,game_id,time_ms,kind,data) values(gen_random_uuid(),p_game,floor(extract(epoch from clock_timestamp())*1000),'review',jsonb_build_object('event',e.id,'before',e.data->'correct','after',p_correct));
  end if;
 end if;
 return public.ps_api('state',p_game,p_token);
end $$;
revoke all on function public.ps_review_event(uuid,text,bigint,boolean) from public;
grant execute on function public.ps_review_event(uuid,text,bigint,boolean) to anon,authenticated;
notify pgrst,'reload schema';
commit;
