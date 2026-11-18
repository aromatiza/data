-- =====================================================================
-- Migration 002 — additifs, produits marocains, liaison produit/additif
-- À lancer APRÈS schema.sql (SQL Editor > Run). Sans danger à relancer.
-- =====================================================================

-- Champs produits en plus
alter table products add column if not exists ingredients_text text;
alter table products add column if not exists image_url text;

-- Additifs (E-codes). name_fr peut être complété par un validateur.
create table if not exists additives (
  id          bigint generated always as identity primary key,
  e_code      text unique,            -- ex: E621 (null si pas de code)
  name_fr     text not null,
  off_tag     text unique,            -- ex: en:e621 (Open Food Facts)
  created_at  timestamptz not null default now()
);

-- Liaison produit <-> additif
create table if not exists product_additives (
  product_id   bigint not null references products(id) on delete cascade,
  additive_id  bigint not null references additives(id) on delete cascade,
  primary key (product_id, additive_id)
);

alter table additives        enable row level security;
alter table product_additives enable row level security;

drop policy if exists "public lit additifs" on additives;
drop policy if exists "equipe ajoute additifs" on additives;
drop policy if exists "equipe modifie additifs" on additives;
drop policy if exists "public lit liens additifs" on product_additives;
drop policy if exists "equipe gere liens additifs" on product_additives;

-- Lecture publique (liste d'additifs, pas de donnée personnelle)
create policy "public lit additifs" on additives for select using (true);
create policy "equipe ajoute additifs" on additives for insert
  with check (my_role() in ('admin', 'validator'));
create policy "equipe modifie additifs" on additives for update
  using (my_role() in ('admin', 'validator'));

create policy "public lit liens additifs" on product_additives for select using (true);
create policy "equipe gere liens additifs" on product_additives for all
  using (my_role() in ('admin', 'validator'))
  with check (my_role() in ('admin', 'validator'));

-- Suppression d'additif : admin seulement
drop policy if exists "admin supprime additifs" on additives;
create policy "admin supprime additifs" on additives for delete
  using (my_role() = 'admin');
