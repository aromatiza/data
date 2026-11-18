-- =====================================================================
-- NutriX Data — schema Supabase (v1)
-- Colle tout ce fichier dans Supabase > SQL Editor > Run.
--
-- Principe :
--   * L'agent (tâche planifiée) écrit seulement des données brutes
--     (recettes, produits) avec le statut 'a_valider'.
--   * Le calcul nutritionnel est fait par la base (vue dish_nutrition)
--     à partir de la table ingredients (TMCA / CIQUAL) : jamais par l'IA.
--   * L'équipe valide dans le site nutrix-data.
--   * L'app NutriX (et le public) ne lit que ce qui est 'valide'.
-- =====================================================================

-- ---------- Types ----------
create type data_status as enum ('draft', 'a_valider', 'valide', 'rejete');
create type team_role   as enum ('admin', 'validator', 'agent');

-- ---------- Équipe (qui a le droit de quoi) ----------
create table team_members (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  full_name  text not null,
  role       team_role not null default 'validator',
  created_at timestamptz not null default now()
);

create or replace function my_role() returns team_role
language sql stable security definer set search_path = public as $$
  select role from team_members where user_id = auth.uid()
$$;

-- ---------- 1. Ingrédients (base scientifique) ----------
-- Valeurs pour 100 g de partie comestible, recopiées depuis la source.
create table ingredients (
  id            bigint generated always as identity primary key,
  name_fr       text not null,
  name_ar       text,
  name_darija   text,
  source        text not null check (source in ('TMCA', 'CIQUAL', 'USDA', 'etiquette', 'labo')),
  source_code   text,                 -- code de l'aliment dans la table source
  source_url    text,
  energy_kcal   numeric(7,2) not null check (energy_kcal >= 0),
  protein_g     numeric(6,2) not null check (protein_g between 0 and 100),
  carbs_g       numeric(6,2) not null check (carbs_g between 0 and 100),
  sugars_g      numeric(6,2)          check (sugars_g between 0 and 100),
  fat_g         numeric(6,2) not null check (fat_g between 0 and 100),
  sat_fat_g     numeric(6,2)          check (sat_fat_g between 0 and 100),
  fiber_g       numeric(6,2)          check (fiber_g between 0 and 100),
  salt_g        numeric(6,3)          check (salt_g between 0 and 100),
  water_g       numeric(6,2)          check (water_g between 0 and 100),
  created_at    timestamptz not null default now(),
  unique (source, source_code)
);

-- ---------- 2. Plats ----------
create table dishes (
  id            bigint generated always as identity primary key,
  name_fr       text not null,
  name_ar       text,
  name_darija   text,
  category      text,                 -- soupe, tajine, pâtisserie, pain...
  portion_g     numeric(7,1),         -- portion marocaine habituelle
  tmca_kcal     numeric(7,2),         -- valeur TMCA si le plat y figure (comparaison)
  status        data_status not null default 'a_valider',
  validated_by  uuid references auth.users(id),
  validated_at  timestamptz,
  created_by    uuid references auth.users(id) default auth.uid(),
  created_at    timestamptz not null default now(),
  unique (name_fr)
);

-- ---------- 3. Recettes (une recette standard par plat, versionnée) ----------
create table recipes (
  id              bigint generated always as identity primary key,
  dish_id         bigint not null references dishes(id) on delete cascade,
  version         int not null default 1,
  servings        int,
  cooked_weight_g numeric(8,1),       -- poids après cuisson (si connu)
  sources         jsonb not null default '[]'::jsonb,  -- [{ "title": "...", "url": "..." }]
  notes           text,
  status          data_status not null default 'a_valider',
  created_by      uuid references auth.users(id) default auth.uid(),
  created_at      timestamptz not null default now(),
  unique (dish_id, version)
);

create table recipe_ingredients (
  id             bigint generated always as identity primary key,
  recipe_id      bigint not null references recipes(id) on delete cascade,
  ingredient_id  bigint references ingredients(id),   -- null = pas encore relié
  raw_label      text not null,                        -- texte d'origine ("2 tomates")
  grams          numeric(8,1) not null check (grams > 0)
);

-- ---------- 4. Produits (code-barres) ----------
create table products (
  id            bigint generated always as identity primary key,
  barcode       text not null unique,
  name          text not null,
  brand         text,
  quantity      text,
  energy_kcal   numeric(7,2) check (energy_kcal >= 0),
  protein_g     numeric(6,2) check (protein_g between 0 and 100),
  carbs_g       numeric(6,2) check (carbs_g between 0 and 100),
  sugars_g      numeric(6,2) check (sugars_g between 0 and 100),
  fat_g         numeric(6,2) check (fat_g between 0 and 100),
  sat_fat_g     numeric(6,2) check (sat_fat_g between 0 and 100),
  fiber_g       numeric(6,2) check (fiber_g between 0 and 100),
  salt_g        numeric(6,3) check (salt_g between 0 and 100),
  source        text not null check (source in ('OpenFoodFacts', 'etiquette')),
  source_url    text,
  status        data_status not null default 'a_valider',
  validated_by  uuid references auth.users(id),
  validated_at  timestamptz,
  created_by    uuid references auth.users(id) default auth.uid(),
  created_at    timestamptz not null default now()
);

-- ---------- 5. Journal de validation ----------
create table review_log (
  id          bigint generated always as identity primary key,
  table_name  text not null check (table_name in ('dishes', 'recipes', 'products')),
  row_id      bigint not null,
  action      text not null check (action in ('valide', 'rejete', 'modifie')),
  reason      text,
  user_id     uuid not null references auth.users(id) default auth.uid(),
  created_at  timestamptz not null default now()
);

-- ---------- Agent : file de priorités + rapports ----------
create table agent_queue (
  id          bigint generated always as identity primary key,
  kind        text not null check (kind in ('dish', 'product')),
  name        text not null,          -- nom du plat ou code-barres
  priority    int not null default 50,
  done        boolean not null default false,
  created_at  timestamptz not null default now()
);

create table agent_runs (
  id              bigint generated always as identity primary key,
  started_at      timestamptz not null default now(),
  finished_at     timestamptz,
  dishes_added    int not null default 0,
  products_added  int not null default 0,
  report          text,
  errors          text
);

-- =====================================================================
-- CALCUL : méthode des recettes (fait par la base, pas par l'IA)
-- valeur_100g = somme(grams_i * valeur_i / 100) / poids_final * 100
-- poids_final = cooked_weight_g si connu, sinon somme des grammes crus.
-- =====================================================================
create or replace view dish_nutrition as
with latest as (
  select distinct on (dish_id) *
  from recipes
  where status <> 'rejete'
  order by dish_id, version desc
),
sums as (
  select
    r.dish_id,
    r.id                                   as recipe_id,
    sum(ri.grams)                          as raw_weight_g,
    coalesce(max(r.cooked_weight_g), sum(ri.grams)) as final_weight_g,
    count(*)                               as n_ingredients,
    count(*) filter (where ri.ingredient_id is null) as n_unlinked,
    sum(ri.grams * i.energy_kcal / 100)    as kcal,
    sum(ri.grams * i.protein_g   / 100)    as protein,
    sum(ri.grams * i.carbs_g     / 100)    as carbs,
    sum(ri.grams * i.fat_g       / 100)    as fat,
    sum(ri.grams * coalesce(i.fiber_g, 0) / 100) as fiber,
    sum(ri.grams * coalesce(i.salt_g, 0)  / 100) as salt
  from latest r
  join recipe_ingredients ri on ri.recipe_id = r.id
  left join ingredients i on i.id = ri.ingredient_id
  group by r.dish_id, r.id
)
select
  d.id                                  as dish_id,
  d.name_fr,
  d.status,
  s.recipe_id,
  s.n_ingredients,
  s.n_unlinked,                         -- > 0 : calcul incomplet
  round(s.kcal    / s.final_weight_g * 100, 1) as energy_kcal_100g,
  round(s.protein / s.final_weight_g * 100, 2) as protein_g_100g,
  round(s.carbs   / s.final_weight_g * 100, 2) as carbs_g_100g,
  round(s.fat     / s.final_weight_g * 100, 2) as fat_g_100g,
  round(s.fiber   / s.final_weight_g * 100, 2) as fiber_g_100g,
  round(s.salt    / s.final_weight_g * 100, 3) as salt_g_100g,
  d.portion_g,
  d.tmca_kcal,
  -- contrôle 1 : Atwater (4P + 4G + 9L + 2 fibres) vs énergie calculée
  round(abs((4*s.protein + 4*s.carbs + 9*s.fat + 2*s.fiber) - s.kcal)
        / nullif(s.kcal, 0) * 100, 1)   as atwater_gap_pct,
  -- contrôle 2 : écart avec la TMCA (si le plat y figure)
  round(abs(s.kcal / s.final_weight_g * 100 - d.tmca_kcal)
        / nullif(d.tmca_kcal, 0) * 100, 1) as tmca_gap_pct
from dishes d
join sums s on s.dish_id = d.id;

-- =====================================================================
-- SÉCURITÉ (Row Level Security)
-- =====================================================================
alter table team_members        enable row level security;
alter table ingredients         enable row level security;
alter table dishes              enable row level security;
alter table recipes             enable row level security;
alter table recipe_ingredients  enable row level security;
alter table products            enable row level security;
alter table review_log          enable row level security;
alter table agent_queue         enable row level security;
alter table agent_runs          enable row level security;

-- Public (app NutriX) : lecture des données validées seulement
create policy "public lit ingredients"  on ingredients for select using (true);
create policy "public lit plats valides" on dishes    for select using (status = 'valide' or my_role() is not null);
create policy "public lit produits valides" on products for select using (status = 'valide' or my_role() is not null);
create policy "lecture recettes" on recipes for select
  using (my_role() is not null
         or exists (select 1 from dishes d where d.id = dish_id and d.status = 'valide'));
create policy "lecture lignes recette" on recipe_ingredients for select
  using (my_role() is not null
         or exists (select 1 from recipes r join dishes d on d.id = r.dish_id
                    where r.id = recipe_id and d.status = 'valide'));

-- Équipe
create policy "equipe se voit" on team_members for select using (my_role() is not null);
create policy "admin gere equipe" on team_members for all
  using (my_role() = 'admin') with check (my_role() = 'admin');

-- Ingrédients : seuls admin/validator modifient la base scientifique
create policy "equipe ecrit ingredients" on ingredients for insert
  with check (my_role() in ('admin', 'validator'));
create policy "equipe modifie ingredients" on ingredients for update
  using (my_role() in ('admin', 'validator'));

-- Agent : peut AJOUTER uniquement en 'a_valider', jamais modifier/valider/supprimer
create policy "agent ajoute plats" on dishes for insert
  with check (my_role() = 'agent' and status = 'a_valider');
create policy "agent ajoute recettes" on recipes for insert
  with check (my_role() = 'agent' and status = 'a_valider');
create policy "agent ajoute lignes" on recipe_ingredients for insert
  with check (my_role() = 'agent');
create policy "agent ajoute produits" on products for insert
  with check (my_role() = 'agent' and status = 'a_valider');

-- Validateurs / admin : ajoutent, modifient et valident
create policy "equipe ajoute plats" on dishes for insert with check (my_role() in ('admin', 'validator'));
create policy "equipe modifie plats" on dishes for update using (my_role() in ('admin', 'validator'));
create policy "equipe ajoute recettes" on recipes for insert with check (my_role() in ('admin', 'validator'));
create policy "equipe modifie recettes" on recipes for update using (my_role() in ('admin', 'validator'));
create policy "equipe gere lignes" on recipe_ingredients for all
  using (my_role() in ('admin', 'validator')) with check (my_role() in ('admin', 'validator'));
create policy "equipe ajoute produits" on products for insert with check (my_role() in ('admin', 'validator'));
create policy "equipe modifie produits" on products for update using (my_role() in ('admin', 'validator'));

-- Journal : l'équipe écrit et lit
create policy "equipe lit journal"   on review_log for select using (my_role() in ('admin', 'validator'));
create policy "equipe ecrit journal" on review_log for insert
  with check (my_role() in ('admin', 'validator') and user_id = auth.uid());

-- Suppression : admin seulement
create policy "admin supprime plats"    on dishes   for delete using (my_role() = 'admin');
create policy "admin supprime produits" on products for delete using (my_role() = 'admin');

-- File et rapports de l'agent
create policy "equipe et agent lisent file" on agent_queue for select using (my_role() is not null);
create policy "equipe gere file" on agent_queue for all
  using (my_role() in ('admin', 'validator')) with check (my_role() in ('admin', 'validator'));
create policy "agent coche file" on agent_queue for update using (my_role() = 'agent');
create policy "equipe lit rapports" on agent_runs for select using (my_role() is not null);
create policy "agent ecrit rapports" on agent_runs for insert with check (my_role() = 'agent');
create policy "agent termine rapport" on agent_runs for update using (my_role() = 'agent');

-- La vue de calcul respecte les droits des tables
alter view dish_nutrition set (security_invoker = true);
