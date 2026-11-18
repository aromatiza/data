-- =====================================================================
-- Migration 003 — images + précision scientifique des plats
-- À lancer APRÈS migration_002 (SQL Editor > Run). Sans danger à relancer.
-- =====================================================================

-- Image du plat (de préférence Wikimedia Commons, licence libre)
alter table dishes add column if not exists image_url     text;
alter table dishes add column if not exists image_credit  text;   -- auteur + licence (ex: "Jean X, CC BY-SA 4.0")
alter table dishes add column if not exists image_source  text;   -- page d'origine de l'image

-- Image du produit : image_url existe déjà (migration 002), on ajoute le crédit
alter table products add column if not exists image_credit text;  -- ex: "Open Food Facts, CC BY-SA"

-- Précision scientifique du plat
alter table dishes add column if not exists region       text;    -- ex: Fès, Marrakech, national
alter table dishes add column if not exists confidence   text
  check (confidence is null or confidence in ('haute', 'moyenne', 'faible'));
alter table dishes add column if not exists method_notes text;    -- comment la recette et les grammes ont été établis
