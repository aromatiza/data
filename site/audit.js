// Audit humain (protocole v1) : checklist + double saisie (produits) → décision.
// L'IA ne valide jamais : seule cette étape fait passer un élément en « validé ».
import { sb, esc } from "./app.js";

export const CHECKLISTS = {
  product: [
    ["identite", "Identification", "Code-barres, marque, nom exact et quantité correspondent à l'emballage (photo)."],
    ["preuve_photo", "Preuve", "Photo de la face et du tableau nutritionnel disponibles et lisibles."],
    ["double_saisie", "Double saisie", "Valeurs re-saisies depuis la photo et identiques aux valeurs enregistrées (formulaire ci-dessous)."],
    ["normalisation", "Normalisation", "Valeurs pour 100 g (ou 100 ml), sel = sodium × 2,5, énergie en kcal."],
    ["plausibilite", "Plausibilité", "Sucres ≤ glucides, AG saturés ≤ lipides, énergie ≈ 4P + 4G + 9L + 2F (± 15 %)."],
    ["classification", "Classification", "Catégorie, groupe NOVA et additifs (codes E) vérifiés sur la liste d'ingrédients."],
    ["scores", "Scores", "Origine du Nutri-Score claire (officiel Open Food Facts ou calculé, version de l'algorithme)."],
    ["ia", "Valeurs IA", "Aucune valeur estimée par l'IA n'est gardée sans contrôle (badges « IA » vérifiés)."],
  ],
  dish: [
    ["definition", "Définition", "Nom, variante et région précis (ex. harira fassia ≠ harira de ramadan à la maison)."],
    ["sources", "Sources", "Au moins 3 sources indépendantes avec quantités, ouvertes et relues (protocole de validation)."],
    ["grammes", "Grammes", "Tous les ingrédients en grammes, poids cru, partie comestible ; conversions justifiées."],
    ["liaison", "Liaison", "Chaque ingrédient relié à la bonne entrée d'une table officielle, dans le bon état (cru, sec, trempé)."],
    ["matiere_grasse", "Matière grasse", "Huile, smen ou beurre de cuisson présents ; pour la friture, part absorbée renseignée (% retenu)."],
    ["cuisson", "Cuisson", "Méthode de cuisson précisée pour chaque ligne (facteurs de rétention des vitamines appliqués)."],
    ["poids_cuit", "Poids cuit", "Poids après cuisson pesé ou sourcé ; sinon, la limite est écrite dans le commentaire."],
    ["plausibilite", "Plausibilité", "Écart Atwater < 10 % et valeurs cohérentes avec des plats comparables."],
    ["portion", "Portion", "Portion habituelle renseignée (pesée ou source)."],
    ["scores", "Scores", "Nutri-Score marqué « calculé, non officiel » et groupe NOVA justifié."],
  ],
};

// Où regarder dans la fiche pour chaque critère (lien « voir »)
const SEE = {
  identite: "s-preuves", preuve_photo: "s-preuves", double_saisie: "s-valeurs", normalisation: "s-valeurs",
  plausibilite: "s-controles", classification: "s-composition", scores: "top", ia: "s-valeurs",
  definition: "top", sources: "s-preuves", grammes: "s-calcul", liaison: "s-calcul", matiere_grasse: "s-calcul",
  cuisson: "s-calcul", poids_cuit: "s-calcul", portion: "s-valeurs",
};

// File d'audit (remplie par la page « À valider ») : position et élément suivant
export function queueInfo(kind, id) {
  try {
    const q = JSON.parse(sessionStorage.getItem("nxQueue") || "null");
    if (!q || q.kind !== kind) return null;
    const i = q.ids.indexOf(id);
    if (i < 0) return null;
    const href = (x) => x === undefined ? null : `fiche.html?${kind === "dish" ? "plat" : "produit"}=${x}#audit`;
    return { pos: i + 1, total: q.ids.length, prev: href(q.ids[i - 1]), next: href(q.ids[i + 1]),
      drop: () => { q.ids.splice(i, 1); sessionStorage.setItem("nxQueue", JSON.stringify(q)); } };
  } catch { return null; }
}

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

export function renderAuditPanel(el, { kind, entity, member, onDone, queue = null }) {
  const items = CHECKLISTS[kind];
  const isProduct = kind === "product";
  el.innerHTML = `
    <div class="panel" id="audit">
      ${queue ? `<div class="queue-nav"><span>${queue.prev ? `<a href="${queue.prev}">← Précédent</a>` : ""}</span>
        <span>Élément ${queue.pos} / ${queue.total}</span>
        <span>${queue.next ? `<a href="${queue.next}">Passer →</a>` : `<a href="a-valider.html">File d'audit</a>`}</span></div>` : ""}
      <h2 style="margin:0">Audit humain</h2>
      <p class="muted" style="margin:4px 0 0">Coche un critère après l'avoir contrôlé toi-même (« voir » ouvre la bonne section). « Valider » s'active quand tout est coché.</p>
      <div class="progress"><i id="audit-prog"></i></div>
      ${isProduct ? `
        <h3 style="font-size:15px;margin:14px 0 4px">Double saisie depuis la photo de l'étiquette</h3>
        <p class="muted">Ouvre la photo du tableau nutritionnel et recopie les valeurs pour 100 g <b>sans regarder</b> les valeurs enregistrées.</p>
        <div class="de-grid">${DE_FIELDS.map(([k, label]) => `<label>${label}<input type="number" step="any" data-de="${k}"></label>`).join("")}</div>
        <div id="de-result" class="muted">Remplis les champs pour comparer.</div>` : ""}
      <div class="checklist" style="margin-top:12px">${items.map(([k, t, d]) => `
        <label><input type="checkbox" data-ck="${k}" ${isProduct && k === "double_saisie" ? "disabled" : ""}>
          <span><b>${esc(t)}</b>${SEE[k] ? `<a class="see" href="#${SEE[k]}">voir</a>` : ""}<small>${esc(d)}</small></span></label>`).join("")}</div>
      <label style="display:block;margin:12px 0 4px;font-size:13px;color:var(--muted)">Commentaire (obligatoire pour « À corriger » et « Rejeter »)</label>
      <textarea id="audit-comment" rows="3" style="width:100%;font:inherit;padding:8px;border:1px solid var(--line);border-radius:6px"></textarea>
      <div class="actions" style="margin-top:12px">
        <button class="primary" id="audit-ok" disabled>Valider</button>
        <button class="accent" id="audit-fix">À corriger</button>
        <button id="audit-rej">Rejeter</button>
        <span id="audit-msg"></span>
      </div>
    </div>`;

  let deResult = null;
  const boxes = () => [...el.querySelectorAll("input[data-ck]")];
  const refresh = () => {
    const done = boxes().filter((b) => b.checked).length;
    el.querySelector("#audit-prog").style.width = (done / boxes().length * 100) + "%";
    el.querySelector("#audit-ok").disabled = done !== boxes().length;
    el.querySelector("#audit-ok").textContent = done === boxes().length ? "Valider" : `Valider (${done}/${boxes().length})`;
  };
  el.querySelectorAll("input[data-ck]").forEach((b) => b.addEventListener("change", refresh));

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
        (filled ? `<br><b>${deResult.all_match ? "Double saisie identique ✓" : "Écarts : corrige la valeur fausse (Modifier) puis refais l'audit."}</b>` : "");
      const ck = el.querySelector('input[data-ck="double_saisie"]');
      ck.checked = deResult.all_match;
      refresh();
    }));
  }

  const say = (t, bad) => { const m = el.querySelector("#audit-msg"); m.textContent = t; m.className = bad ? "tag warn" : "tag ok"; };

  async function decide(decision) {
    const comment = el.querySelector("#audit-comment").value.trim();
    if (decision !== "valide" && !comment) { say("Écris un commentaire.", true); return; }
    const checklist = Object.fromEntries(boxes().map((b) => [b.dataset.ck, b.checked]));
    el.querySelectorAll("button").forEach((b) => { b.disabled = true; });
    const id = kind === "dish" ? entity.dish_id ?? entity.id : entity.id;
    const table = kind === "dish" ? "dishes" : "products";
    const now = new Date().toISOString();

    const { error: e1 } = await sb.from("human_audits").insert({
      entity_kind: kind, entity_id: id, checklist, double_entry: isProduct ? deResult : null,
      decision, comment: comment || null, auditor_id: member.user.id, auditor_name: member.name || member.user.email,
    });
    if (e1) { say(e1.message, true); el.querySelectorAll("button").forEach((b) => { b.disabled = false; }); refresh(); return; }

    let upd;
    if (decision === "valide") {
      upd = { status: "valide", validated_by: member.user.id, validated_at: now, validated_source: "humain" };
      if (isProduct) {
        const due = new Date(); due.setMonth(due.getMonth() + 18);
        Object.assign(upd, { double_entry_ok: true, values_source: "etiquette", recheck_due: due.toISOString().slice(0, 10) });
      }
    } else if (decision === "rejete") {
      upd = { status: "rejete", validated_by: member.user.id, validated_at: now };
    } else {
      upd = { status: "a_valider", audited_at: null };
    }
    const { error: e2 } = await sb.from(table).update(upd).eq("id", id);
    if (e2) { say(e2.message, true); return; }
    if (kind === "dish" && decision !== "a_corriger") await sb.from("recipes").update({ status: upd.status }).eq("dish_id", id);
    await sb.from("review_log").insert({
      table_name: table, row_id: id, action: decision === "a_corriger" ? "modifie" : decision,
      reason: `Audit humain v1${comment ? " : " + comment : ""}`,
    });
    say(decision === "valide" ? "Validé ✓" : decision === "rejete" ? "Rejeté" : "Renvoyé pour correction");
    onDone?.(decision);
  }
  el.querySelector("#audit-ok").onclick = () => decide("valide");
  el.querySelector("#audit-fix").onclick = () => decide("a_corriger");
  el.querySelector("#audit-rej").onclick = () => decide("rejete");
  refresh();
}
