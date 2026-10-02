-- BoonifyMe: run once in Supabase > SQL Editor.
-- Then: Authentication > Providers > Email > turn OFF "Allow new users to sign up".
-- Invite each teammate from Authentication > Users. Make yourself admin with:
--   update profiles set role='admin' where id=(select id from auth.users where email='YOU@EXAMPLE.COM');

create table profiles(id uuid primary key references auth.users on delete cascade, name text, role text not null default 'editor' check (role in ('admin','editor')));
create table pay_rates(user_id uuid primary key references profiles on delete cascade, rate numeric not null default 15);
create table settings(id int primary key default 1 check (id=1), cfg jsonb not null);
insert into settings values (1, '{"edit":0.75,"target":25,"bonus":10,"minP":5,"from":9,"to":17,"short":"amzn.to, a.co, bit.ly, tinyurl.com, shope.ee"}');
create table products(id uuid primary key default gen_random_uuid(), name text not null, cat text, rating numeric default 4, verdict text, sizing text, img text, asin text, offers jsonb not null default '[]', live boolean not null default false, updated_by uuid default auth.uid(), updated_at timestamptz not null default now());
create table shifts(id uuid primary key default gen_random_uuid(), user_id uuid not null default auth.uid() references profiles, clock_in timestamptz not null default now(), clock_out timestamptz, ok boolean);
create table edits(id uuid primary key default gen_random_uuid(), shift_id uuid not null references shifts on delete cascade, user_id uuid not null default auth.uid(), product_id uuid not null references products on delete cascade, at timestamptz not null default now(), unique(shift_id, product_id));
create table sales(id uuid primary key default gen_random_uuid(), asin text not null, earnings numeric not null, period date not null);

create function is_admin() returns boolean language sql security definer stable set search_path=public as $$ select exists(select 1 from profiles where id=auth.uid() and role='admin') $$;
create function new_user() returns trigger language plpgsql security definer set search_path=public as $$ begin
  insert into profiles(id,name) values(new.id, split_part(new.email,'@',1)); insert into pay_rates(user_id) values(new.id); return new; end $$;
create trigger on_signup after insert on auth.users for each row execute function new_user();

alter table profiles enable row level security; alter table pay_rates enable row level security; alter table settings enable row level security;
alter table products enable row level security; alter table shifts enable row level security; alter table edits enable row level security; alter table sales enable row level security;

create policy "team reads profiles" on profiles for select to authenticated using (true);
create policy "admin edits profiles" on profiles for update to authenticated using (is_admin());
create policy "own or admin rate" on pay_rates for select to authenticated using (user_id=auth.uid() or is_admin());
create policy "admin sets rates" on pay_rates for update to authenticated using (is_admin());
create policy "team reads settings" on settings for select to authenticated using (true);
create policy "admin edits settings" on settings for update to authenticated using (is_admin());
create policy "public sees live products" on products for select to anon using (live);
create policy "team sees all products" on products for select to authenticated using (true);
create policy "team adds products" on products for insert to authenticated with check (true);
create policy "team edits products" on products for update to authenticated using (true);
create policy "admin deletes products" on products for delete to authenticated using (is_admin());
create policy "own or admin shifts" on shifts for select to authenticated using (user_id=auth.uid() or is_admin());
create policy "clock in" on shifts for insert to authenticated with check (user_id=auth.uid());
create policy "clock out" on shifts for update to authenticated using (user_id=auth.uid());
create policy "own or admin edits" on edits for select to authenticated using (user_id=auth.uid() or is_admin());
create policy "log own edits" on edits for insert to authenticated with check (user_id=auth.uid() and exists(select 1 from shifts s where s.id=shift_id and s.user_id=auth.uid() and s.clock_out is null));
create policy "admin only sales" on sales for all to authenticated using (is_admin()) with check (is_admin());

-- Sales credit: each product's Amazon earnings are split between the people who worked on it,
-- in proportion to how many shifts each of them edited it. Nobody types sales in by hand.
create function pay_summary() returns table(user_id uuid, name text, rate numeric, hours numeric, products bigint, shifts_missed bigint, sales numeric)
language sql security definer stable set search_path=public as $$
  with w as (select product_id, e.user_id as uid, count(*) n from edits e group by 1,2),
  t as (select product_id, sum(n) tot from w group by 1),
  c as (select w.uid, sum(s.earnings * w.n / t.tot) sales from sales s join products p on p.asin=s.asin join w on w.product_id=p.id join t on t.product_id=p.id group by 1)
  select p.id, p.name, r.rate,
    coalesce((select sum(extract(epoch from coalesce(sh.clock_out, now())-sh.clock_in))/3600 from shifts sh where sh.user_id=p.id),0),
    (select count(*) from edits e where e.user_id=p.id),
    (select count(*) from shifts sh where sh.user_id=p.id and sh.clock_out is not null and sh.ok is false),
    coalesce(c.sales,0)
  from profiles p join pay_rates r on r.user_id=p.id left join c on c.uid=p.id
  where is_admin() or p.id=auth.uid() $$;
