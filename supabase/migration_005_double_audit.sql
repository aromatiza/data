-- =====================================================================
-- Migration 005 — Double audit humain (protocole v2)
--
--  * Chaque fiche (plat ou produit) passe par 2 auditeurs différents.
--    - Les 2 sont d'accord          → décision finale (validé ou rejeté).
--    - Les 2 ne sont pas d'accord   → 3e audit = arbitrage (commentaire obligatoire).
--    - « À corriger » à n'importe quel moment → la fiche revient en brouillon,
--      un nouveau cycle d'audit commence après la correction.
--  * Le statut de la fiche est changé ici, dans la base (trigger) :
--    le site ne peut plus valider sans double audit.
--  * Journal des modifications (avant → après + source) dans human_audits.changes.
--
-- Additif : n'efface aucune donnée. À exécuter une fois dans le SQL Editor.
-- =====================================================================

alter table human_audits add column if not exists cycle smallint;
alter table human_audits add column if not exists round smallint;
alter table human_audits add column if not exists role text;
alter table human_audits add column if not exists changes jsonb not null default '[]'::jsonb;

alter table human_audits drop constraint if exists human_audits_role_check;
alter table human_audits add constraint human_audits_role_check
  check (role is null or role in ('auditeur_1', 'auditeur_2', 'arbitre'));

-- Anciennes lignes (s'il y en a) : chacune devient le 1er audit de son propre cycle.
update human_audits h set cycle = s.c, round = 1, role = 'auditeur_1'
from (select id, row_number() over (partition by entity_kind, entity_id order by created_at)::smallint as c
      from human_audits) s
where h.id = s.id and h.cycle is null;

create index if not exists human_audits_cycle_idx on human_audits (entity_kind, entity_id, cycle, round);

-- ---------- 1. Avant l'insertion : cycle, rang, rôle, règles ----------
create or replace function human_audit_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  c smallint;
  n int;
  has_fix boolean;
  d1 text;
  d2 text;
begin
  select max(cycle) into c from human_audits
   where entity_kind = new.entity_kind and entity_id = new.entity_id;

  if c is null then
    c := 1; n := 0;
  else
    select count(*), bool_or(decision = 'a_corriger'),
           max(decision) filter (where round = 1), max(decision) filter (where round = 2)
      into n, has_fix, d1, d2
      from human_audits
     where entity_kind = new.entity_kind and entity_id = new.entity_id and cycle = c;
    -- Cycle terminé ? (correction demandée, accord des 2, ou arbitrage fait)
    if has_fix or n >= 3 or (n = 2 and d1 = d2) then
      c := c + 1; n := 0;
    end if;
  end if;

  new.cycle := c;
  new.round := n + 1;
  new.role := case new.round when 1 then 'auditeur_1' when 2 then 'auditeur_2' else 'arbitre' end;

  if new.round = 2 and exists (
      select 1 from human_audits
       where entity_kind = new.entity_kind and entity_id = new.entity_id
         and cycle = c and auditor_id = new.auditor_id) then
    raise exception 'Le 2e audit doit être fait par un autre membre de l''équipe.';
  end if;

  if new.round = 3 and coalesce(btrim(new.comment), '') = '' then
    raise exception 'Arbitrage : un commentaire expliquant la décision est obligatoire.';
  end if;

  if new.decision <> 'valide' and coalesce(btrim(new.comment), '') = '' then
    raise exception 'Commentaire obligatoire pour « À corriger » et « Rejeter ».';
  end if;

  if new.changes is null then new.changes := '[]'::jsonb; end if;
  new.protocol_version := coalesce(new.protocol_version, 'v2');
  return new;
end $$;

drop trigger if exists human_audit_before_trg on human_audits;
create trigger human_audit_before_trg before insert on human_audits
  for each row execute function human_audit_before();

-- ---------- 2. Après l'insertion : statut de la fiche ----------
create or replace function human_audit_after() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  d1 text;
  final_decision text;
  de_ok boolean;
  tbl text := case new.entity_kind when 'dish' then 'dishes' else 'products' end;
  why text;
begin
  if new.decision = 'a_corriger' then
    if new.entity_kind = 'dish' then
      update dishes set status = 'a_valider', audited_at = null where id = new.entity_id;
    else
      update products set status = 'a_valider', audited_at = null where id = new.entity_id;
    end if;
    insert into review_log (table_name, row_id, action, reason, user_id)
    values (tbl, new.entity_id, 'modifie',
            'Audit humain ' || new.role || ' : à corriger — ' || coalesce(new.comment, ''), new.auditor_id);
    return new;
  end if;

  if new.round = 1 then
    return new;                                   -- attend le 2e auditeur
  elsif new.round = 2 then
    select decision into d1 from human_audits
     where entity_kind = new.entity_kind and entity_id = new.entity_id and cycle = new.cycle and round = 1;
    if d1 is distinct from new.decision then
      insert into review_log (table_name, row_id, action, reason, user_id)
      values (tbl, new.entity_id, 'modifie',
              'Double audit : désaccord (' || coalesce(d1, '?') || ' / ' || new.decision || ') → arbitrage nécessaire', new.auditor_id);
      return new;                                 -- attend l'arbitre
    end if;
    final_decision := new.decision;
    why := 'Double audit : accord des 2 auditeurs';
  else
    final_decision := new.decision;
    why := 'Arbitrage : ' || coalesce(new.comment, '');
  end if;

  if final_decision = 'valide' then
    if new.entity_kind = 'dish' then
      update dishes set status = 'valide', validated_by = new.auditor_id, validated_at = now(),
                        validated_source = 'humain' where id = new.entity_id;
      update recipes set status = 'valide' where dish_id = new.entity_id and status <> 'rejete';
    else
      select bool_or(coalesce((double_entry ->> 'all_match')::boolean, false)) into de_ok
        from human_audits
       where entity_kind = 'product' and entity_id = new.entity_id and cycle = new.cycle and decision = 'valide';
      update products set status = 'valide', validated_by = new.auditor_id, validated_at = now(),
                          validated_source = 'humain',
                          double_entry_ok = coalesce(de_ok, false),
                          values_source = case when de_ok then 'etiquette' else values_source end,
                          recheck_due = (now() + interval '18 months')::date
       where id = new.entity_id;
    end if;
  else
    if new.entity_kind = 'dish' then
      update dishes set status = 'rejete', validated_by = new.auditor_id, validated_at = now() where id = new.entity_id;
      update recipes set status = 'rejete' where dish_id = new.entity_id;
    else
      update products set status = 'rejete', validated_by = new.auditor_id, validated_at = now() where id = new.entity_id;
    end if;
  end if;

  insert into review_log (table_name, row_id, action, reason, user_id)
  values (tbl, new.entity_id, final_decision, why, new.auditor_id);
  return new;
end $$;

drop trigger if exists human_audit_after_trg on human_audits;
create trigger human_audit_after_trg after insert on human_audits
  for each row execute function human_audit_after();
