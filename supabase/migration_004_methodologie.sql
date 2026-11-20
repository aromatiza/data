-- =====================================================================
-- Migration 004 — Protocole de recherche v1 (méthodologie scientifique)
-- Pré-requis : migration 004a →  alter type data_status add value if not exists 'verifie' before 'valide';
-- Sans danger à relancer.
--
-- Contenu :
--  1. Niveaux de preuve S1–S5 (source_levels) + niveau sur ingrédients et produits
--  2. Preuves (evidence) : photos, pages, tables, articles, pesées, analyses
--  3. Cuisson : méthode par recette et par ligne, part retenue (friture), pesées (weighings)
--  4. Vitamines et minéraux des ingrédients + facteurs de rétention (USDA Release 6)
--  5. Audit humain (human_audits) avec checklist et double saisie
--  6. Vue dish_nutrition : rendement mesuré, huile absorbée, rétention des vitamines
--  7. Lecture publique (page jury) et passage des produits auto-validés en « vérifié »
-- =====================================================================

-- ---------- 1. Niveaux de preuve ----------
create table if not exists source_levels (
  level smallint primary key check (level between 1 and 5),
  code text not null unique,
  name_fr text not null,
  description text not null
);
insert into source_levels (level, code, name_fr, description) values
  (1, 'S1', 'Analyse de laboratoire', 'Analyse chimique du produit ou du plat par un laboratoire (méthodes normalisées AOAC / ISO).'),
  (2, 'S2', 'Source primaire officielle', 'Photo de l''étiquette vérifiée par l''équipe (double saisie), ou table de composition officielle (TMCA, CIQUAL, USDA FoodData Central).'),
  (3, 'S3', 'Fabricant ou publication', 'Fiche technique du fabricant, publication scientifique, ouvrage de référence, recette documentée avec quantités.'),
  (4, 'S4', 'Base collaborative', 'Open Food Facts : données saisies par des contributeurs, non vérifiées par l''équipe.'),
  (5, 'S5', 'Estimation IA', 'Valeur lue ou estimée par l''IA, à vérifier par un humain avant toute utilisation scientifique.')
on conflict (level) do update set code = excluded.code, name_fr = excluded.name_fr, description = excluded.description;
alter table source_levels enable row level security;
drop policy if exists "public lit niveaux" on source_levels;
create policy "public lit niveaux" on source_levels for select using (true);

-- Ingrédients : niveau, groupe de rétention, vitamines et minéraux (pour 100 g, partie comestible, cru)
alter table ingredients
  add column if not exists source_level smallint check (source_level between 1 and 5),
  add column if not exists retention_group text check (retention_group is null or retention_group in
    ('legumes_feuilles','legumes_racines','legumes_autres','legumineuses','cereales_pates','riz','cereales_bouillie',
     'viande_boeuf','viande_agneau','volaille','poisson','oeufs','pommes_de_terre','laitiers','fruits','autre')),
  add column if not exists vit_c_mg      numeric check (vit_c_mg >= 0),
  add column if not exists thiamin_mg    numeric check (thiamin_mg >= 0),
  add column if not exists riboflavin_mg numeric check (riboflavin_mg >= 0),
  add column if not exists niacin_mg     numeric check (niacin_mg >= 0),
  add column if not exists vit_b6_mg     numeric check (vit_b6_mg >= 0),
  add column if not exists folate_ug     numeric check (folate_ug >= 0),
  add column if not exists vit_b12_ug    numeric check (vit_b12_ug >= 0),
  add column if not exists vit_a_ug      numeric check (vit_a_ug >= 0),
  add column if not exists vit_e_mg      numeric check (vit_e_mg >= 0),
  add column if not exists vit_d_ug      numeric check (vit_d_ug >= 0),
  add column if not exists iron_mg       numeric check (iron_mg >= 0),
  add column if not exists calcium_mg    numeric check (calcium_mg >= 0),
  add column if not exists magnesium_mg  numeric check (magnesium_mg >= 0),
  add column if not exists zinc_mg       numeric check (zinc_mg >= 0),
  add column if not exists potassium_mg  numeric check (potassium_mg >= 0),
  add column if not exists micros_source_url text,
  add column if not exists micros_checked_at timestamptz;

update ingredients set source_level = case source when 'labo' then 1 when 'etiquette' then 4 else 2 end
where source_level is null;

create or replace function set_ingredient_level() returns trigger language plpgsql
set search_path = public as $$
begin
  if new.source_level is null or (tg_op = 'UPDATE' and new.source is distinct from old.source) then
    new.source_level := case new.source when 'labo' then 1 when 'etiquette' then 4 else 2 end;
  end if;
  return new;
end $$;
drop trigger if exists trg_ingredient_level on ingredients;
create trigger trg_ingredient_level before insert or update on ingredients
  for each row execute function set_ingredient_level();

-- Produits : niveau de preuve, version de l'algorithme du score, double saisie, date de re-vérification
alter table products
  add column if not exists source_level smallint check (source_level between 1 and 5),
  add column if not exists algorithm_version text,
  add column if not exists double_entry_ok boolean,
  add column if not exists recheck_due date;

create or replace function set_product_level() returns trigger language plpgsql
set search_path = public as $$
begin
  if new.source_level is null or (tg_op = 'UPDATE' and new.values_source is distinct from old.values_source) then
    new.source_level := case coalesce(new.values_source, 'OpenFoodFacts')
      when 'etiquette' then 2 when 'manuel' then 3 when 'photo_etiquette_ia' then 5 else 4 end;
  end if;
  new.algorithm_version := case new.scores_source
    when 'OpenFoodFacts' then 'Nutri-Score officiel (Open Food Facts)'
    when 'calcul' then 'Nutri-Score 2023, calcul NutriX v1 (non officiel)'
    else new.algorithm_version end;
  return new;
end $$;
drop trigger if exists trg_products_zz_level on products;   -- « zz » : s'exécute après trg_products_scores
create trigger trg_products_zz_level before insert or update on products
  for each row execute function set_product_level();
update products set source_level = null;   -- déclenche le calcul du niveau et de algorithm_version

-- ---------- 2. Preuves ----------
create table if not exists evidence (
  id bigint generated always as identity primary key,
  entity_kind text not null check (entity_kind in ('dish','product','ingredient','recipe')),
  entity_id bigint not null,
  kind text not null check (kind in ('photo_face','photo_tableau','photo_ingredients','photo_codebarre','page_web',
    'recette_source','table_composition','article_scientifique','analyse_labo','pesee','autre')),
  title text not null,
  url text,
  source_level smallint check (source_level between 1 and 5),
  quote text,                                -- ce que la source dit exactement (valeur, quantité)
  accessed_at date default current_date,
  added_by text not null default 'equipe' check (added_by in ('equipe','agent')),
  created_by uuid default auth.uid() references auth.users(id),
  created_at timestamptz default now()
);
create index if not exists evidence_entity_idx on evidence (entity_kind, entity_id);
alter table evidence enable row level security;
drop policy if exists "public lit preuves" on evidence;
create policy "public lit preuves" on evidence for select using (true);
drop policy if exists "equipe ajoute preuves" on evidence;
create policy "equipe ajoute preuves" on evidence for insert with check (my_role() is not null);
drop policy if exists "equipe modifie preuves" on evidence;
create policy "equipe modifie preuves" on evidence for update using (my_role() in ('admin','validator'));
drop policy if exists "admin supprime preuves" on evidence;
create policy "admin supprime preuves" on evidence for delete using (my_role() = 'admin');

-- Reprise des sources déjà enregistrées
insert into evidence (entity_kind, entity_id, kind, title, url, source_level, added_by)
select 'dish', r.dish_id, 'recette_source', coalesce(nullif(s->>'title',''), 'Source de la recette'), s->>'url', 3, 'agent'
from recipes r cross join lateral jsonb_array_elements(case when jsonb_typeof(r.sources) = 'array' then r.sources else '[]'::jsonb end) s
where not exists (select 1 from evidence e where e.entity_kind = 'dish' and e.entity_id = r.dish_id and e.url is not distinct from s->>'url');

insert into evidence (entity_kind, entity_id, kind, title, url, source_level, added_by)
select 'product', p.id, 'page_web', 'Fiche Open Food Facts', p.source_url, 4, 'agent'
from products p where p.source_url is not null
  and not exists (select 1 from evidence e where e.entity_kind = 'product' and e.entity_id = p.id and e.url = p.source_url);

insert into evidence (entity_kind, entity_id, kind, title, url, source_level, added_by)
select 'product', p.id, 'photo_face', 'Photo du produit (' || coalesce(p.image_credit, 'Open Food Facts') || ')', p.image_url, 4, 'agent'
from products p where p.image_url is not null
  and not exists (select 1 from evidence e where e.entity_kind = 'product' and e.entity_id = p.id and e.url = p.image_url);

insert into evidence (entity_kind, entity_id, kind, title, url, source_level, added_by)
select 'ingredient', i.id, 'table_composition', i.source || coalesce(' ' || i.source_code, ''), i.source_url, i.source_level, 'agent'
from ingredients i where i.source_url is not null
  and not exists (select 1 from evidence e where e.entity_kind = 'ingredient' and e.entity_id = i.id and e.url = i.source_url);

-- ---------- 3. Cuisson et pesées ----------
alter table recipes
  add column if not exists cooking_method text,
  add column if not exists cooked_weight_basis text check (cooked_weight_basis is null or cooked_weight_basis in ('pese','source','non_mesure')),
  add column if not exists liquid_consumed boolean;      -- le liquide de cuisson est-il mangé (soupe, tajine) ?
update recipes set cooked_weight_basis = case when cooked_weight_g is not null then 'source' else 'non_mesure' end
where cooked_weight_basis is null;

alter table recipe_ingredients
  add column if not exists cooking_method text,
  add column if not exists retained_pct numeric not null default 100 check (retained_pct > 0 and retained_pct <= 100),
  add column if not exists state text check (state is null or state in ('cru','cuit','sec','trempe','egoutte'));

do $$ begin
  alter table recipes add constraint recipes_cooking_method_chk check (cooking_method is null or cooking_method in
    ('cru','bouilli_peu_eau','bouilli_egoutte','bouilli_eau_gardee','mijote','revenu_mijote','braise','frit','four','vapeur','grille'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table recipe_ingredients add constraint ri_cooking_method_chk check (cooking_method is null or cooking_method in
    ('cru','bouilli_peu_eau','bouilli_egoutte','bouilli_eau_gardee','mijote','revenu_mijote','braise','frit','four','vapeur','grille'));
exception when duplicate_object then null; end $$;

create table if not exists weighings (
  id bigint generated always as identity primary key,
  recipe_id bigint not null references recipes(id) on delete cascade,
  performed_on date not null default current_date,
  performed_by text,
  raw_total_g numeric not null check (raw_total_g > 0),       -- ingrédients crus mis en cuisson, huile de friture exclue
  cooked_total_g numeric not null check (cooked_total_g > 0), -- plat cuit, égoutté
  oil_before_g numeric check (oil_before_g >= 0),             -- huile de friture avant
  oil_after_g numeric check (oil_after_g >= 0),               -- huile de friture restante après
  portion_g numeric check (portion_g > 0),
  notes text,
  photo_url text,
  created_by uuid default auth.uid() references auth.users(id),
  created_at timestamptz default now()
);
create index if not exists weighings_recipe_idx on weighings (recipe_id);
alter table weighings enable row level security;
drop policy if exists "public lit pesees" on weighings;
create policy "public lit pesees" on weighings for select using (true);
drop policy if exists "equipe gere pesees" on weighings;
create policy "equipe gere pesees" on weighings for all
  using (my_role() in ('admin','validator')) with check (my_role() in ('admin','validator'));

-- ---------- 4. Facteurs de rétention ----------
create table if not exists retention_factors (
  id bigint generated always as identity primary key,
  code text not null,                 -- code USDA (ex. '0651')
  line_label text not null,           -- libellé tel qu'imprimé dans la table USDA
  food_group text not null,
  cooking_method text not null,
  nutrient text not null check (nutrient in ('vit_c_mg','thiamin_mg','riboflavin_mg','niacin_mg','vit_b6_mg','folate_ug',
    'vit_b12_ug','vit_a_ug','vit_e_mg','vit_d_ug','iron_mg','calcium_mg','magnesium_mg','zinc_mg','potassium_mg')),
  retention_pct numeric not null check (retention_pct >= 0 and retention_pct <= 100),
  source text not null,
  source_url text,
  verified boolean not null default false,
  verified_note text,
  unique (code, nutrient),
  unique (food_group, cooking_method, nutrient)
);
alter table retention_factors enable row level security;
drop policy if exists "public lit retention" on retention_factors;
create policy "public lit retention" on retention_factors for select using (true);
drop policy if exists "equipe gere retention" on retention_factors;
create policy "equipe gere retention" on retention_factors for all
  using (my_role() in ('admin','validator')) with check (my_role() in ('admin','validator'));

with lines(code, label, grp, method, v) as (values
  ('0501','LEGUMES,CKD 15/20MIN,BOILED,DRAINED','legumineuses','bouilli_egoutte', array[65,65,75,70,70,60,100,85,85,85,80,85,75]),
  ('0381','PASTA,BOILED,DRAINED','cereales_pates','bouilli_egoutte', array[70,65,75,65,80,70,100,95,75,95,85,100,30]),
  ('0384','PASTA,BOILED,NOT DRAINED','cereales_pates','bouilli_eau_gardee', array[80,80,90,90,90,70,100,95,100,100,100,100,100]),
  ('0431','RICE,WHITE/BROWN,COOKED,DRAINED','riz','bouilli_egoutte', array[75,75,90,95,90,60,100,95,90,95,95,95,85]),
  ('0432','RICE,WHITE/BROWN,COOKED,WATER USED','riz','bouilli_eau_gardee', array[80,80,90,100,95,70,100,95,95,100,100,100,95]),
  ('0358','CEREAL,REG/QUICK,COOKED','cereales_bouillie','bouilli_eau_gardee', array[80,80,90,90,90,70,100,90,95,100,100,100,95]),
  ('0651','BEEF,ROAST,BRAISED,WO/DRIPPINGS','viande_boeuf','braise', array[80,45,85,55,35,65,60,75,100,80,65,100,55]),
  ('0653','BEEF,ROAST,SIMMERED,WO/DRIPPINGS','viande_boeuf','mijote', array[80,45,85,55,35,65,60,75,100,80,65,100,55]),
  ('1051','LAMB,BROWN,SIMMER,WO/DRIPPINGS','viande_agneau','revenu_mijote', array[80,30,60,60,45,55,60,75,95,100,65,95,55]),
  ('1055','LAMB,SIMMERED,WO/DRIPPINGS','viande_agneau','mijote', array[80,30,60,60,55,55,60,75,95,100,65,95,55]),
  ('0855','CHICKEN,SIMMERED,WO/DRIPPINGS','volaille','mijote', array[80,55,95,60,50,60,50,75,90,80,65,100,60]),
  ('2301','FINFISH,<5%FAT,BAKED,WO/DRIPPINGS','poisson','four', array[80,90,95,95,90,90,90,90,100,100,100,100,100]),
  ('2309','FINFISH,<5%FAT,FRIED,WO/COATING','poisson','frit', array[80,85,95,100,90,90,90,85,100,100,100,100,100]),
  ('0103','EGGS,FRIED,SCRAMBLED','oeufs','frit', array[80,85,95,95,95,75,85,100,100,100,100,100,100]),
  ('0105','EGGS,HARD COOKED','oeufs','bouilli_egoutte', array[80,85,95,95,95,75,85,100,100,100,100,100,100]),
  ('3315','POTATOES,FRIED','pommes_de_terre','frit', array[80,80,95,95,95,75,100,100,100,100,100,100,100]),
  ('3004','VEG,GREENS,BOILD,LITTLE WATER DRAIN','legumes_feuilles','bouilli_peu_eau', array[60,85,95,90,90,65,100,95,95,95,95,95,90]),
  ('3005','VEG,GREENS,BOILED,WATER COVER DRAIN','legumes_feuilles','bouilli_egoutte', array[55,80,90,85,85,60,100,95,95,95,95,95,85]),
  ('3454','VEG,ROOTS,ETC,BLD,DRAIND,LITTLE WTR','legumes_racines','bouilli_peu_eau', array[70,85,95,95,95,70,100,90,95,95,95,95,90]),
  ('3455','VEG,ROOTS,ETC,BLD,DRAIND,WTR COVER','legumes_racines','bouilli_egoutte', array[65,80,90,90,90,65,100,90,95,95,95,95,90]),
  ('3774','VEG,OTHER,BLD,LITTLE WATER,DRAINED','legumes_autres','bouilli_peu_eau', array[80,85,95,90,90,70,100,90,95,95,95,95,90]),
  ('3775','VEG,OTHER,BLD,WATER COVER,DRAINED','legumes_autres','bouilli_egoutte', array[75,80,90,85,85,65,100,90,95,95,95,95,90])
), nut(idx, name) as (values
  (1,'vit_c_mg'),(2,'thiamin_mg'),(3,'riboflavin_mg'),(4,'niacin_mg'),(5,'vit_b6_mg'),(6,'folate_ug'),(7,'vit_b12_ug'),
  (8,'vit_a_ug'),(9,'iron_mg'),(10,'calcium_mg'),(11,'magnesium_mg'),(12,'zinc_mg'),(13,'potassium_mg'))
insert into retention_factors (code, line_label, food_group, cooking_method, nutrient, retention_pct, source, source_url, verified, verified_note)
select l.code, l.label, l.grp, l.method, n.name, l.v[n.idx],
  'USDA Table of Nutrient Retention Factors, Release 6 (2007)', 'https://www.ars.usda.gov/Services/docs.htm?docid=9448', false,
  'Transcrit du PDF Release 6 ; à contrôler ligne par ligne sur le PDF original avant usage scientifique.'
from lines l cross join nut n
on conflict (code, nutrient) do nothing;

create or replace function retention_factor(p_group text, p_method text, p_nutrient text) returns numeric
language sql stable set search_path = public as $$
  select case when p_method is null or p_method = 'cru' then 1
    else (select rf.retention_pct / 100 from retention_factors rf
          where rf.food_group = p_group and rf.cooking_method = p_method and rf.nutrient = p_nutrient) end
$$;

-- ---------- 5. Audit humain ----------
create table if not exists human_audits (
  id bigint generated always as identity primary key,
  entity_kind text not null check (entity_kind in ('dish','product')),
  entity_id bigint not null,
  protocol_version text not null default 'v1',
  checklist jsonb not null,           -- { clé_du_critère: true/false }
  double_entry jsonb,                 -- produits : valeurs re-saisies depuis la photo + écarts
  decision text not null check (decision in ('valide','a_corriger','rejete')),
  comment text,
  auditor_id uuid default auth.uid() references auth.users(id),
  auditor_name text,
  created_at timestamptz default now()
);
create index if not exists human_audits_entity_idx on human_audits (entity_kind, entity_id);
alter table human_audits enable row level security;
drop policy if exists "public lit audits humains" on human_audits;
create policy "public lit audits humains" on human_audits for select using (true);
drop policy if exists "equipe ecrit audits humains" on human_audits;
create policy "equipe ecrit audits humains" on human_audits for insert
  with check (my_role() in ('admin','validator') and auditor_id = auth.uid());

-- Audits IA lisibles par le jury pour les éléments validés
drop policy if exists "public lit audits des valides" on audits;
create policy "public lit audits des valides" on audits for select using (
  entity_kind = 'ingredient'
  or (entity_kind = 'dish' and exists (select 1 from dishes d where d.id = audits.entity_id and d.status = 'valide'))
  or (entity_kind = 'product' and exists (select 1 from products p where p.id = audits.entity_id and p.status = 'valide')));

-- ---------- 6. Vue dish_nutrition (mêmes colonnes qu'avant + nouvelles à la fin) ----------
create or replace view dish_nutrition with (security_invoker = true) as
with latest as (
  select distinct on (recipes.dish_id) recipes.*
  from recipes where recipes.status <> 'rejete'::data_status
  order by recipes.dish_id, recipes.version desc
), pes as (
  select w.recipe_id, count(*) as n_weighings,
    avg(w.cooked_total_g / nullif(w.raw_total_g + coalesce(greatest(w.oil_before_g - w.oil_after_g, 0), 0), 0)) as yield_ratio
  from weighings w group by w.recipe_id
), lines as (
  select r.dish_id, r.id as recipe_id, r.cooked_weight_g, r.cooking_method as recipe_method,
    ri.ingredient_id, ri.grams, ri.grams * coalesce(ri.retained_pct, 100) / 100 as g,
    coalesce(ri.cooking_method, r.cooking_method) as method,
    i.id as iid, i.energy_kcal, i.protein_g, i.carbs_g, i.fat_g, i.fiber_g, i.salt_g, i.sugars_g, i.sat_fat_g,
    i.fvl_pct, i.water_g, i.nova_group, i.source_level, i.retention_group, i.micros_checked_at,
    i.vit_c_mg, i.thiamin_mg, i.riboflavin_mg, i.niacin_mg, i.vit_b6_mg, i.folate_ug, i.vit_b12_ug, i.vit_a_ug,
    i.vit_e_mg, i.vit_d_ug, i.iron_mg, i.calcium_mg, i.magnesium_mg, i.zinc_mg, i.potassium_mg
  from latest r
  join recipe_ingredients ri on ri.recipe_id = r.id
  left join ingredients i on i.id = ri.ingredient_id
), sums as (
  select l.dish_id, l.recipe_id,
    sum(l.grams) as raw_weight_g,
    sum(l.g) as eff_weight_g,
    max(l.cooked_weight_g) as source_cooked_g,
    count(*) as n_ingredients,
    count(*) filter (where l.ingredient_id is null) as n_unlinked,
    sum(l.g * l.energy_kcal / 100) as kcal,
    sum(l.g * l.protein_g / 100) as protein,
    sum(l.g * l.carbs_g / 100) as carbs,
    sum(l.g * l.fat_g / 100) as fat,
    sum(l.g * coalesce(l.fiber_g, 0) / 100) as fiber,
    sum(l.g * coalesce(l.salt_g, 0) / 100) as salt,
    sum(l.g * coalesce(l.sugars_g, 0) / 100) as sugars,
    sum(l.g * coalesce(l.sat_fat_g, 0) / 100) as satfat,
    sum(l.g * coalesce(l.fvl_pct, 0) / 100) / nullif(sum(l.g) filter (where coalesce(l.water_g, 0) < 99.5), 0) * 100 as fvl,
    max(l.nova_group) filter (where l.nova_group <> 2) as nova_main,
    max(l.nova_group) as nova_all,
    count(*) filter (where l.iid is not null and l.nova_group is null) as n_nova_missing,
    max(l.source_level) as worst_source_level,
    count(*) filter (where l.method is null) as n_method_missing,
    count(*) filter (where l.iid is not null and l.method is not null and l.method <> 'cru'
                     and retention_factor(l.retention_group, l.method, 'vit_c_mg') is null) as n_retention_missing,
    count(*) filter (where l.iid is not null and l.micros_checked_at is null) as n_micros_missing,
    -- vitamines et minéraux : brut (cru) puis après cuisson (facteur de rétention, 1 si absent)
    sum(l.g * l.vit_c_mg / 100) as r_vit_c, sum(l.g * l.vit_c_mg / 100 * coalesce(retention_factor(l.retention_group, l.method, 'vit_c_mg'), 1)) as c_vit_c,
    sum(l.g * l.thiamin_mg / 100) as r_thi, sum(l.g * l.thiamin_mg / 100 * coalesce(retention_factor(l.retention_group, l.method, 'thiamin_mg'), 1)) as c_thi,
    sum(l.g * l.riboflavin_mg / 100) as r_rib, sum(l.g * l.riboflavin_mg / 100 * coalesce(retention_factor(l.retention_group, l.method, 'riboflavin_mg'), 1)) as c_rib,
    sum(l.g * l.niacin_mg / 100) as r_nia, sum(l.g * l.niacin_mg / 100 * coalesce(retention_factor(l.retention_group, l.method, 'niacin_mg'), 1)) as c_nia,
    sum(l.g * l.vit_b6_mg / 100) as r_b6, sum(l.g * l.vit_b6_mg / 100 * coalesce(retention_factor(l.retention_group, l.method, 'vit_b6_mg'), 1)) as c_b6,
    sum(l.g * l.folate_ug / 100) as r_fol, sum(l.g * l.folate_ug / 100 * coalesce(retention_factor(l.retention_group, l.method, 'folate_ug'), 1)) as c_fol,
    sum(l.g * l.vit_b12_ug / 100) as r_b12, sum(l.g * l.vit_b12_ug / 100 * coalesce(retention_factor(l.retention_group, l.method, 'vit_b12_ug'), 1)) as c_b12,
    sum(l.g * l.vit_a_ug / 100) as r_va, sum(l.g * l.vit_a_ug / 100 * coalesce(retention_factor(l.retention_group, l.method, 'vit_a_ug'), 1)) as c_va,
    sum(l.g * l.vit_e_mg / 100) as r_ve, sum(l.g * l.vit_e_mg / 100 * coalesce(retention_factor(l.retention_group, l.method, 'vit_e_mg'), 1)) as c_ve,
    sum(l.g * l.vit_d_ug / 100) as r_vd, sum(l.g * l.vit_d_ug / 100 * coalesce(retention_factor(l.retention_group, l.method, 'vit_d_ug'), 1)) as c_vd,
    sum(l.g * l.iron_mg / 100) as r_fe, sum(l.g * l.iron_mg / 100 * coalesce(retention_factor(l.retention_group, l.method, 'iron_mg'), 1)) as c_fe,
    sum(l.g * l.calcium_mg / 100) as r_ca, sum(l.g * l.calcium_mg / 100 * coalesce(retention_factor(l.retention_group, l.method, 'calcium_mg'), 1)) as c_ca,
    sum(l.g * l.magnesium_mg / 100) as r_mg, sum(l.g * l.magnesium_mg / 100 * coalesce(retention_factor(l.retention_group, l.method, 'magnesium_mg'), 1)) as c_mg,
    sum(l.g * l.zinc_mg / 100) as r_zn, sum(l.g * l.zinc_mg / 100 * coalesce(retention_factor(l.retention_group, l.method, 'zinc_mg'), 1)) as c_zn,
    sum(l.g * l.potassium_mg / 100) as r_k, sum(l.g * l.potassium_mg / 100 * coalesce(retention_factor(l.retention_group, l.method, 'potassium_mg'), 1)) as c_k
  from lines l
  group by l.dish_id, l.recipe_id
), weighted as (
  select s.*, p.n_weighings, p.yield_ratio,
    case when p.yield_ratio is not null then s.eff_weight_g * p.yield_ratio
         when s.source_cooked_g is not null then s.source_cooked_g
         else s.eff_weight_g end as final_weight_g,
    case when p.yield_ratio is not null then 'pese'
         when s.source_cooked_g is not null then 'source'
         else 'non_mesure' end as weight_basis
  from sums s left join pes p on p.recipe_id = s.recipe_id
), calc as (
  select d.name_fr, d.status, d.nova_manual, d.portion_g, d.tmca_kcal, w.*,
    w.kcal / w.final_weight_g * 100 as k100,
    w.sugars / w.final_weight_g * 100 as su100,
    w.satfat / w.final_weight_g * 100 as sf100,
    w.salt / w.final_weight_g * 100 as sa100,
    w.fiber / w.final_weight_g * 100 as fi100,
    w.protein / w.final_weight_g * 100 as pr100
  from dishes d join weighted w on w.dish_id = d.id
), res as (
  select c.*,
    ns.score as ns_score, ns.grade as ns_grade
  from calc c
  cross join lateral nutriscore_2023(c.k100, c.su100, c.sf100, c.sa100, c.fi100, c.pr100, c.fvl) ns(score, grade)
)
select
  r.dish_id, r.name_fr, r.status, r.recipe_id, r.n_ingredients, r.n_unlinked,
  round(r.k100, 1) as energy_kcal_100g,
  round(r.pr100, 2) as protein_g_100g,
  round(r.carbs / r.final_weight_g * 100, 2) as carbs_g_100g,
  round(r.fat / r.final_weight_g * 100, 2) as fat_g_100g,
  round(r.fi100, 2) as fiber_g_100g,
  round(r.sa100, 3) as salt_g_100g,
  r.portion_g, r.tmca_kcal,
  round(abs(4 * r.protein + 4 * r.carbs + 9 * r.fat + 2 * r.fiber - r.kcal) / nullif(r.kcal, 0) * 100, 1) as atwater_gap_pct,
  round(abs(r.k100 - r.tmca_kcal) / nullif(r.tmca_kcal, 0) * 100, 1) as tmca_gap_pct,
  round(r.su100, 2) as sugars_g_100g,
  round(r.sf100, 2) as sat_fat_g_100g,
  round(r.fvl, 1) as fvl_pct,
  r.ns_score as nutriscore_score,
  case when r.n_unlinked = 0 then r.ns_grade else null end as nutriscore_grade,
  coalesce(r.nova_manual, case when r.n_unlinked = 0 and r.n_nova_missing = 0 then coalesce(r.nova_main, r.nova_all) else null::smallint end) as nova_group,
  r.nova_manual is not null as nova_is_manual,
  case when r.n_unlinked = 0 then nutrix_rating(r.ns_score,
    coalesce(r.nova_manual, case when r.n_nova_missing = 0 then coalesce(r.nova_main, r.nova_all) else null::smallint end)) else null::integer end as rating,
  -- Nouvelles colonnes (protocole v1)
  round(r.raw_weight_g, 1) as raw_weight_g,
  round(r.final_weight_g, 1) as final_weight_g,
  r.weight_basis,
  round(r.final_weight_g / nullif(r.eff_weight_g, 0) * 100, 1) as yield_pct,
  coalesce(r.n_weighings, 0) as n_weighings,
  r.worst_source_level,
  r.n_method_missing,
  r.n_retention_missing,
  r.n_micros_missing,
  jsonb_strip_nulls(jsonb_build_object(
    'vit_c_mg', round(r.r_vit_c / r.final_weight_g * 100, 2), 'thiamin_mg', round(r.r_thi / r.final_weight_g * 100, 3),
    'riboflavin_mg', round(r.r_rib / r.final_weight_g * 100, 3), 'niacin_mg', round(r.r_nia / r.final_weight_g * 100, 3),
    'vit_b6_mg', round(r.r_b6 / r.final_weight_g * 100, 3), 'folate_ug', round(r.r_fol / r.final_weight_g * 100, 1),
    'vit_b12_ug', round(r.r_b12 / r.final_weight_g * 100, 2), 'vit_a_ug', round(r.r_va / r.final_weight_g * 100, 1),
    'vit_e_mg', round(r.r_ve / r.final_weight_g * 100, 2), 'vit_d_ug', round(r.r_vd / r.final_weight_g * 100, 2),
    'iron_mg', round(r.r_fe / r.final_weight_g * 100, 2), 'calcium_mg', round(r.r_ca / r.final_weight_g * 100, 1),
    'magnesium_mg', round(r.r_mg / r.final_weight_g * 100, 1), 'zinc_mg', round(r.r_zn / r.final_weight_g * 100, 2),
    'potassium_mg', round(r.r_k / r.final_weight_g * 100, 1))) as micros_raw_100g,
  jsonb_strip_nulls(jsonb_build_object(
    'vit_c_mg', round(r.c_vit_c / r.final_weight_g * 100, 2), 'thiamin_mg', round(r.c_thi / r.final_weight_g * 100, 3),
    'riboflavin_mg', round(r.c_rib / r.final_weight_g * 100, 3), 'niacin_mg', round(r.c_nia / r.final_weight_g * 100, 3),
    'vit_b6_mg', round(r.c_b6 / r.final_weight_g * 100, 3), 'folate_ug', round(r.c_fol / r.final_weight_g * 100, 1),
    'vit_b12_ug', round(r.c_b12 / r.final_weight_g * 100, 2), 'vit_a_ug', round(r.c_va / r.final_weight_g * 100, 1),
    'vit_e_mg', round(r.c_ve / r.final_weight_g * 100, 2), 'vit_d_ug', round(r.c_vd / r.final_weight_g * 100, 2),
    'iron_mg', round(r.c_fe / r.final_weight_g * 100, 2), 'calcium_mg', round(r.c_ca / r.final_weight_g * 100, 1),
    'magnesium_mg', round(r.c_mg / r.final_weight_g * 100, 1), 'zinc_mg', round(r.c_zn / r.final_weight_g * 100, 2),
    'potassium_mg', round(r.c_k / r.final_weight_g * 100, 1))) as micros_cooked_100g
from res r;

-- ---------- 7. Statistiques publiques (page jury) ----------
create or replace function public_stats() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'dishes', (select jsonb_object_agg(status, n) from (select status::text, count(*) n from dishes group by 1) x),
    'products', (select jsonb_object_agg(status, n) from (select status::text, count(*) n from products group by 1) x),
    'ingredients', (select count(*) from ingredients),
    'ingredients_by_level', (select jsonb_object_agg(coalesce(source_level::text, '?'), n) from (select source_level, count(*) n from ingredients group by 1) x),
    'products_by_level', (select jsonb_object_agg(coalesce(source_level::text, '?'), n) from (select source_level, count(*) n from products group by 1) x),
    'evidence', (select count(*) from evidence),
    'weighings', (select count(*) from weighings),
    'human_audits', (select count(*) from human_audits),
    'ai_audits', (select count(*) from audits),
    'retention_factors', (select count(*) from retention_factors),
    'ingredients_micros_ok', (select count(*) from ingredients where micros_checked_at is not null)
  )
$$;
revoke all on function public_stats() from public;
grant execute on function public_stats() to anon, authenticated;

-- ---------- 8. L'audit IA ne valide plus : produits auto-validés → « vérifié » ----------
with moved as (
  update products set status = 'verifie'
  where status = 'valide' and validated_source = 'audit_ia'
  returning id
)
insert into review_log (table_name, row_id, action, reason, user_id)
select 'products', id, 'modifie', 'Protocole v1 : l''audit IA ne valide plus. Passé en « vérifié », en attente de l''audit humain.', null
from moved;
update dishes set status = 'verifie' where status = 'valide' and validated_source = 'audit_ia';
