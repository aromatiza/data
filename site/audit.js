// Audit humain (protocole v2) : checklist + double saisie (produits) + journal des modifications.
// Double audit : 2 membres différents ; en cas de désaccord, un 3e audit (arbitrage) tranche.
// Le statut de la fiche est changé par la base (trigger, migration 005), jamais par le navigateur.
// L'IA ne valide jamais : seule cette étape fait passer un élément en « validé ».
import { sb, esc } from "./app.js";

export const CHECKLISTS = {
  product: [
    ["identite", "Identification", "Code-barres, marque, nom exact et quantité correspondent à l'emballage (photo)."],
    ["preuve_photo", "Preuve", "Photos de la face, du tableau nutritionnel et de la liste d'ingrédients disponibles et lisibles."],
    ["double_saisie", "Double saisie", "Valeurs re-saisies depuis la photo et identiques aux valeurs enregistrées (formulaire ci-dessous)."],
    ["normalisation", "Normalisation", "Valeurs pour 100 g (ou 100 ml), sel = sodium × 2,5, énergie en kcal."],
    ["plausibilite", "Plausibilité", "Sucres ≤ glucides, AG saturés ≤ lipides, énergie ≈ 4P + 4G + 9L + 2F (± 15 %)."],
    ["classification", "Classification", "Catégorie, groupe NOVA et additifs (codes E) vérifiés sur la liste d'ingrédients."],
    ["scores", "Scores", "Origine du Nutri-Score claire (officiel Open Food Facts ou calculé, version de l'algorithme)."],
    ["ia", "Valeurs IA", "Aucune valeur estimée par l'IA n'est gardée sans contrôle (badges « IA » vérifiés)."],
    ["doublon", "Doublon", "Le produit n'existe pas déjà dans la base (même code-barres, même produit sous un autre nom)."],
  ],
  dish: [
    ["definition", "Définition", "Nom, variante et région précis (ex. harira fassia ≠ harira de ramadan à la maison)."],
    ["sources", "Sources", "Au moins 3 recettes indépendantes avec quantités, comparées en % (recette standardisée = médiane)."],
    ["grammes", "Grammes", "Tous les ingrédients en grammes, poids cru, partie comestible ; conversions justifiées."],
    ["liaison", "Liaison", "Chaque ingrédient relié à la bonne entrée d'une table officielle, dans le bon état (cru, sec, trempé)."],
    ["matiere_grasse", "Matière grasse", "Huile, smen ou beurre de cuisson présents ; pour la friture, part absorbée renseignée (% retenu)."],
    ["cuisson", "Cuisson", "Méthode de cuisson précisée pour chaque ligne (facteurs de rétention des vitamines appliqués)."],
    ["poids_cuit", "Poids cuit", "Poids après cuisson pesé ou sourcé ; sinon, la limite est écrite dans le commentaire."],
    ["plausibilite", "Plausibilité", "Écart Atwater < 10 % et valeurs cohérentes avec des plats comparables."],
    ["portion", "Portion", "Portion habituelle renseignée (pesée ou source)."],
    ["scores", "Scores", "Nutri-Score marqué « calculé, non officiel » et groupe NOVA justifié."],
    ["image", "Image", "Photo réelle (équipe) ou libre de droits avec crédit ; jamais une image IA comme preuve."],
  ],
};

const DE_FIELDS = [
  ["energy_kcal", "Énergie (kcal)", 0.5], ["fat_g", "Lipides (g)", 0.05], ["sat_fat_g", "dont AG saturés (g)", 0.05],
  ["carbs_g", "Glucides (g)", 0.05], ["sugars_g", "dont sucres (g)", 0.05], ["fiber_g", "Fibres (g)", 0.05],
  ["protein_g", "Protéines (g)", 0.05], ["salt_g", "Sel (g)", 0.005],
];

// Contrôles automatiques affichés à l'auditeur (aide à la décision, pas une décision)
export function productChecks(p) {
  const out = [];
  const n = (x) => (x === null || x === undefined || x === "" ? null : Number(x));
  if (n(p.sugars_g) !== null && n(p.carbs_g) !== null) out.push([n(p.sugars_g) <= n(p.carbs_g), "Sucres ≤ glucides"]);
  if (n(p.sat_fat_g) !== null && n(p.fat_g) !== null) out.push([n(p.sat_fat_g) <= n(p.fat_g), "AG saturés ≤ lipides"]);
  if ([p.energy_kcal, p.protein_g, p.carbs_g, p.fat_g].every((x) => n(x) !== null)) {
    const calc = 4 * n(p.protein_g) + 4 * n(p.carbs_g) + 9 * n(p.fat_g) + 2 * (n(p.fiber_g) || 0);
    const gap = n(p.energy_kcal) ? Math.abs(calc - n(p.energy_kcal)) / n(p.energy_kcal) * 100 : null;
    if (gap !== null) out.push([gap <= 15, `Énergie déclarée ${n(p.energy_kcal)} kcal vs calculée ${calc.toFixed(0)} kcal (écart ${gap.toFixed(1)} %)`]);
  }
  const macros = ["protein_g", "carbs_g", "fat_g", "fiber_g", "salt_g"].reduce((a, k) => a + (n(p[k]) || 0), 0);
  out.push([macros <= 100, `Somme des macronutriments ${macros.toFixed(1)} g ≤ 100 g`]);
  if (!p.image_url) out.push([false, "Pas de photo"]);
  return out;
}

export const PROTOCOL_VERSION = "v2";
export const DECISION_LABEL = { valide: "Validé", a_corriger: "À corriger", rejete: "Rejeté" };
export const ROLE_LABEL = { auditeur_1: "Auditeur 1", auditeur_2: "Auditeur 2", arbitre: "Arbitre" };

// Même règle que le trigger human_audit_before (migration 005) :
// un cycle se termine par une correction demandée, l'accord des 2 auditeurs ou un arbitrage.
export function cycleState(audits) {
  const list = (audits || []).slice().sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
  if (!list.length) return { cycle: 1, round: 1, prev: [], open: false };
  const c = Math.max(...list.map((a) => a.cycle || 1));
  const cur = list.filter((a) => (a.cycle || 1) === c).sort((a, b) => (a.round || 1) - (b.round || 1));
  const n = cur.length;
  const closed = cur.some((a) => a.decision === "a_corriger") || n >= 3 || (n === 2 && cur[0].decision === cur[1].decision);
  return closed ? { cycle: c + 1, round: 1, prev: [], open: false, last: cur } : { cycle: c, round: n + 1, prev: cur, open: true };
}

const CHANGE_FIELDS = {
  product: ["energy_kcal", "protein_g", "carbs_g", "sugars_g", "fat_g", "sat_fat_g", "fiber_g", "salt_g", "name", "brand", "barcode", "ingredients_text", "nova_group", "nutriscore_grade", "category", "image_url"],
  dish: ["ingrédient (quantité)", "ingrédient ajouté", "ingrédient retiré", "liaison à la table", "méthode de cuisson", "% retenu (friture)", "poids cuit", "portion_g", "nom / variante", "source", "image", "autre"],
};

export function renderAuditPanel(el, { kind, entity, member, audits = [], onDone }) {
  const items = CHECKLISTS[kind];
  const isProduct = kind === "product";
  const st = cycleState(audits);
  const me = member.user.id;
  const already = st.prev.some((a) => a.auditor_id === me);
  const blocked = st.round === 2 && already;
  const role = st.round === 1 ? "auditeur_1" : st.round === 2 ? "auditeur_2" : "arbitre";

  const intro = st.round === 1
    ? `<p>Tu es <b>l'auditeur 1</b> de ce cycle. Ensuite, <b>un autre membre</b> refait l'audit sans voir ta décision. Si vous êtes d'accord, la décision est finale.</p>`
    : st.round === 2
      ? `<p>Tu es <b>l'auditeur 2</b> (audit à l'aveugle). L'audit 1 a été fait par <b>${esc(st.prev[0].auditor_name || "un membre")}</b> le ${new Date(st.prev[0].created_at).toLocaleDateString("fr-FR")} ; sa décision reste cachée jusqu'à la tienne.</p>`
      : `<p><b>Arbitrage</b> : les 2 auditeurs ne sont pas d'accord. Lis leurs décisions, discute avec eux, puis décide. Le commentaire est obligatoire.</p>
         <div class="tblwrap"><table><thead><tr><th>Rôle</th><th>Auditeur</th><th>Décision</th><th>Critères non cochés</th><th>Commentaire</th></tr></thead><tbody>
         ${st.prev.map((a) => `<tr><td>${esc(ROLE_LABEL[a.role] || "")}</td><td>${esc(a.auditor_name || "")}</td><td><b>${esc(DECISION_LABEL[a.decision] || a.decision)}</b></td>
           <td>${Object.entries(a.checklist || {}).filter(([, v]) => !v).map(([k]) => esc(k)).join(", ") || "aucun"}</td><td>${esc(a.comment || "")}</td></tr>`).join("")}
         </tbody></table></div>`;

  el.innerHTML = `
    <div class="panel" id="audit">
      <h2>Audit humain — protocole ${PROTOCOL_VERSION} <span class="tag">${esc(ROLE_LABEL[role])} · cycle ${st.cycle}</span></h2>
      ${intro}
      ${blocked ? `<p class="notice">Tu as déjà fait l'audit 1 de ce cycle. Le 2e audit doit être fait par un autre membre de l'équipe.</p>` : `
      <label class="field">Nom de l'auditeur *<input id="audit-name" value="${esc(member.name || "")}" placeholder="Prénom Nom"></label>
      <p class="muted">Coche chaque critère seulement après l'avoir contrôlé toi-même sur les preuves de cette page.
        « Valider » n'est possible que si tous les critères sont cochés. Ta décision est enregistrée avec ton nom et la date.</p>
      ${isProduct ? `
        <h3 class="sub">1. Double saisie depuis la photo de l'étiquette</h3>
        <p class="muted">Ouvre la photo du tableau nutritionnel et recopie les valeurs pour 100 g <b>sans regarder</b> les valeurs enregistrées.</p>
        <div class="de-grid">${DE_FIELDS.map(([k, label]) => `<label>${label}<input type="number" step="any" data-de="${k}"></label>`).join("")}</div>
        <div id="de-result" class="muted">Remplis les champs pour comparer.</div>` : ""}
      <h3 class="sub">${isProduct ? "2" : "1"}. Checklist</h3>
      <div class="checklist">${items.map(([k, t, d]) => `
        <label><input type="checkbox" data-ck="${k}" ${isProduct && k === "double_saisie" ? "disabled" : ""}>
          <span><b>${esc(t)}</b><small>${esc(d)}</small></span></label>`).join("")}</div>
      <h3 class="sub">${isProduct ? "3" : "2"}. Journal des modifications</h3>
      <p class="muted">Une ligne par valeur que tu as corrigée (avec « Modifier ») pendant cet audit : avant → après + la source. Laisse vide si rien n'a changé.</p>
      <datalist id="chg-fields">${CHANGE_FIELDS[kind].map((f) => `<option value="${esc(f)}">`).join("")}</datalist>
      <div class="tblwrap"><table class="chg"><thead><tr><th>Champ</th><th>Avant</th><th>Après</th><th>Source / raison</th><th></th></tr></thead><tbody id="chg-rows"></tbody></table></div>
      <button type="button" id="chg-add" style="margin-top:6px">+ Ajouter une modification</button>
      <h3 class="sub">${isProduct ? "4" : "3"}. Décision</h3>
      <label class="field">Commentaire ${st.round === 3 ? "(obligatoire pour l'arbitrage)" : "(obligatoire pour « À corriger » et « Rejeter »)"}
        <textarea id="audit-comment" rows="3"></textarea></label>
      <div class="actions" style="margin-top:12px">
        <button class="primary" id="audit-ok" disabled>Valider</button>
        <button class="accent" id="audit-fix">À corriger</button>
        <button id="audit-rej">Rejeter</button>
        <span id="audit-msg"></span>
      </div>`}
    </div>`;
  if (blocked) return;

  let deResult = null;
  const boxes = () => [...el.querySelectorAll("input[data-ck]")];
  const refresh = () => { el.querySelector("#audit-ok").disabled = !boxes().every((b) => b.checked); };
  el.querySelectorAll("input[data-ck]").forEach((b) => b.addEventListener("change", refresh));

  const rowsEl = el.querySelector("#chg-rows");
  const addRow = () => {
    const tr = document.createElement("tr");
    tr.innerHTML = `<td><input list="chg-fields" data-c="field" placeholder="champ"></td><td><input data-c="before"></td>
      <td><input data-c="after"></td><td><input data-c="source" placeholder="étiquette, CIQUAL…, pesée"></td>
      <td><button type="button" title="Supprimer la ligne">×</button></td>`;
    tr.querySelector("button").onclick = () => tr.remove();
    rowsEl.appendChild(tr);
  };
  el.querySelector("#chg-add").onclick = addRow;
  const readChanges = () => [...rowsEl.querySelectorAll("tr")].map((tr) => Object.fromEntries(
    [...tr.querySelectorAll("input[data-c]")].map((i) => [i.dataset.c, i.value.trim()])))
    .filter((c) => c.field || c.before || c.after);

  if (isProduct) {
    el.querySelectorAll("input[data-de]").forEach((inp) => inp.addEventListener("input", () => {
      const rows = [], entered = {};
      let filled = 0, ok = true;
      for (const [k, label, tol] of DE_FIELDS) {
        const v = el.querySelector(`input[data-de="${k}"]`).value;
        const stored = entity[k];
        if (v === "") { if (stored !== null && stored !== undefined) ok = false; continue; }
        filled++; entered[k] = Number(v);
        const same = stored !== null && stored !== undefined && Math.abs(Number(v) - Number(stored)) <= tol;
        if (!same) ok = false;
        rows.push(`<span class="${same ? "de-ok" : "de-bad"}">${same ? "✓" : "✗"} ${esc(label)} : saisi ${esc(v)} · enregistré ${esc(stored ?? "vide")}</span>`);
      }
      deResult = { entered, all_match: ok && filled > 0 };
      el.querySelector("#de-result").innerHTML = rows.join("<br>") +
        (filled ? `<br><b>${deResult.all_match ? "Double saisie identique ✓" : "Écarts : corrige la valeur fausse (Modifier), note-la dans le journal, puis refais l'audit."}</b>` : "");
      const ck = el.querySelector('input[data-ck="double_saisie"]');
      ck.checked = deResult.all_match;
      refresh();
    }));
  }

  const say = (t, bad) => { const m = el.querySelector("#audit-msg"); m.textContent = t; m.className = bad ? "tag warn" : "tag ok"; };

  async function decide(decision) {
    const comment = el.querySelector("#audit-comment").value.trim();
    const name = el.querySelector("#audit-name").value.trim();
    if (!name) { say("Écris ton nom (auditeur).", true); return; }
    if ((decision !== "valide" || st.round === 3) && !comment) { say("Écris un commentaire.", true); return; }
    const changes = readChanges();
    if (changes.some((c) => !c.field || !c.source)) { say("Journal : chaque ligne a besoin d'un champ et d'une source.", true); return; }
    const checklist = Object.fromEntries(boxes().map((b) => [b.dataset.ck, b.checked]));
    el.querySelectorAll("button").forEach((b) => { b.disabled = true; });
    const id = kind === "dish" ? entity.dish_id ?? entity.id : entity.id;

    const { data: row, error } = await sb.from("human_audits").insert({
      entity_kind: kind, entity_id: id, protocol_version: PROTOCOL_VERSION, checklist,
      double_entry: isProduct ? deResult : null, changes, decision,
      comment: comment || null, auditor_id: me, auditor_name: name,
    }).select("round, role, cycle").single();
    if (error) { say(error.message, true); el.querySelectorAll("button").forEach((b) => { b.disabled = false; }); refresh(); return; }

    let msg;
    if (decision === "a_corriger") msg = "Renvoyé pour correction : un nouveau cycle d'audit commencera après la correction.";
    else if (row.round === 1) msg = "Audit 1/2 enregistré. Un autre membre doit maintenant faire l'audit 2.";
    else if (row.round === 2 && st.prev[0]?.decision === decision) msg = `Les 2 auditeurs sont d'accord → ${DECISION_LABEL[decision]}.`;
    else if (row.round === 2) msg = "Désaccord avec l'auditeur 1 → un arbitrage (3e audit) est nécessaire.";
    else msg = `Arbitrage enregistré → ${DECISION_LABEL[decision]}.`;
    say(msg);
    onDone?.(decision, row);
  }
  el.querySelector("#audit-ok").onclick = () => decide("valide");
  el.querySelector("#audit-fix").onclick = () => decide("a_corriger");
  el.querySelector("#audit-rej").onclick = () => decide("rejete");
}
