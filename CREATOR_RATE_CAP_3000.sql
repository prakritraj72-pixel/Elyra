-- ELYRA CREATOR RATE SAFETY
-- Enforce the product rule: creator hourly rate must be between ₹1 and ₹3,000.
-- Run once in Supabase SQL Editor.

create or replace function public.validate_creator_hourly_rate()
returns trigger
language plpgsql
as $$
begin
  if new.hourly_rate is null or new.hourly_rate < 1 or new.hourly_rate > 3000 then
    raise exception 'Hourly rate must be between ₹1 and ₹3,000.';
  end if;
  return new;
end;
$$;

drop trigger if exists validate_creator_hourly_rate on public.creator_profiles;
create trigger validate_creator_hourly_rate
before insert or update of hourly_rate on public.creator_profiles
for each row
execute function public.validate_creator_hourly_rate();
