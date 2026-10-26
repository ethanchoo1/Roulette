-- Run once in the Supabase SQL Editor after enabling the Cron extension.
-- Cron calls the server-owned function, which locks expired rounds, advances
-- spins, selects results, and settles winning bets.
select cron.schedule(
  'roulette-night-advance',
  '1 second',
  'select public.system_advance_rounds();'
);
