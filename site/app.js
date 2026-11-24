// Outils partagés : connexion Supabase, garde d'accès, échappement HTML.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const { SUPABASE_URL, SUPABASE_ANON_KEY } = window.NUTRIX_CONFIG;
export const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

export function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

// Renvoie { user, role } si connecté et membre de l'équipe, sinon redirige vers login.
export async function requireTeamMember() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) {
    // Sur la page de connexion (index), on ne redirige pas : sinon boucle infinie.
    const onIndex = /(^|\/)(index\.html)?$/.test(location.pathname);
    if (!onIndex) location.href = "index.html";
    return null;
  }
  const { data: member, error } = await sb
    .from("team_members")
    .select("role, full_name")
    .eq("user_id", session.user.id)
    .maybeSingle();
  if (error || !member) {
    await sb.auth.signOut();
    document.body.innerHTML = "<p class='notice'>Ce compte n'est pas dans l'équipe NutriX.</p>";
    return null;
  }
  return { user: session.user, role: member.role, name: member.full_name };
}

export function nav(active) {
  const items = [
    ["index.html", "Tableau de bord"],
    ["a-valider.html", "File d'audit"],
    ["valides.html", "Validés"],
    ["produits.html", "Produits"],
    ["jury.html", "Preuves (jury)"],
    ["methodologie.html", "Méthodologie"],
  ];
  return `<nav class="side">
    <div class="brand">NutriX Data</div>
    ${items.map(([href, label]) =>
      `<a href="${href}" class="${href === active ? "on" : ""}">${label}${href === "a-valider.html" ? `<span class="count" id="nav-q" hidden></span>` : ""}</a>`).join("")}
    <button id="logout" class="link">Se déconnecter</button>
  </nav>`;
}

export function wireLogout() {
  document.getElementById("logout")?.addEventListener("click", async () => {
    await sb.auth.signOut();
    location.href = "index.html";
  });
  refreshQueueCount();
}

// Nombre d'éléments en attente d'audit, affiché dans le menu
export async function refreshQueueCount() {
  const el = document.getElementById("nav-q");
  if (!el) return;
  const st = ["a_valider", "verifie"];
  const [a, b] = await Promise.all([
    sb.from("dishes").select("*", { count: "exact", head: true }).in("status", st),
    sb.from("products").select("*", { count: "exact", head: true }).in("status", st),
  ]);
  const n = (a.count || 0) + (b.count || 0);
  if (n) { el.textContent = n; el.hidden = false; }
}

// Badges Nutri-Score (A à E) et NOVA (1 à 4)
export function nutriBadge(grade, title = "") {
  const g = String(grade || "").toLowerCase();
  const ok = ["a", "b", "c", "d", "e"].includes(g);
  return `<span class="ns ns-${ok ? g : "x"}" title="Nutri-Score ${esc(title)}">${ok ? g.toUpperCase() : "?"}</span>`;
}
export function novaBadge(group, title = "") {
  const n = Number(group);
  const ok = [1, 2, 3, 4].includes(n);
  return `<span class="nova nova-${ok ? n : "x"}" title="NOVA ${esc(title)}">NOVA ${ok ? n : "?"}</span>`;
}

// Note NutriX /100 (même formule que la fonction SQL nutrix_rating) :
// 70 % points Nutri-Score 2023 (-6 → 100, 30 → 0) + 30 % NOVA (1 → 100, 2 → 80, 3 → 60, 4 → 20)
export function nutrixRating(nsScore, nova) {
  if (nsScore === null || nsScore === undefined || isNaN(nsScore)) return null;
  const nut = Math.max(0, Math.min(100, (30 - nsScore) / 36 * 100));
  const nv = { 1: 100, 2: 80, 3: 60, 4: 20 }[Number(nova)];
  return Math.round(nv === undefined ? nut : 0.7 * nut + 0.3 * nv);
}
export function ratingBadge(r) {
  if (r === null || r === undefined) return `<span class="rate rate-x" title="Note NutriX indisponible">–/100</span>`;
  const c = r >= 75 ? "g" : r >= 50 ? "y" : r >= 25 ? "o" : "r";
  return `<span class="rate rate-${c}" title="Note NutriX : 70 % Nutri-Score + 30 % NOVA">${r}<small>/100</small></span>`;
}

// ---------- Catégories (table categories, kind 'dish' ou 'product') ----------
export async function loadCategories(kind) {
  const { data, error } = await sb.from("categories")
    .select("slug, name_fr, name_darija, sort").eq("kind", kind).order("sort");
  if (error) console.warn("categories:", error.message);
  return data || [];
}

export function categoryName(cats, slug) {
  if (!slug) return "Sans catégorie";
  return cats.find((c) => c.slug === slug)?.name_fr || slug;
}

// Rangée de boutons : « Tout » + chaque catégorie qui contient au moins un élément.
// state.cat = "" (tout), un slug, ou "__none" (sans catégorie). onPick(slug) au clic.
export function renderCategoryBar(el, cats, items, getCat, state, onPick) {
  const counts = {};
  items.forEach((it) => { const c = getCat(it) || "__none"; counts[c] = (counts[c] || 0) + 1; });
  const known = new Set(cats.map((c) => c.slug));
  const list = [["", "Tout", items.length, ""]];
  cats.forEach((c) => { if (counts[c.slug]) list.push([c.slug, c.name_fr, counts[c.slug], c.name_darija || ""]); });
  Object.keys(counts).filter((s) => s !== "__none" && !known.has(s))
    .forEach((s) => list.push([s, s, counts[s], ""]));
  if (counts.__none) list.push(["__none", "Sans catégorie", counts.__none, ""]);
  if (state.cat && !list.some(([s]) => s === state.cat)) state.cat = "";
  el.innerHTML = list.map(([slug, label, n, darija]) =>
    `<button type="button" class="catbtn ${slug === state.cat ? "on" : ""}" data-cat="${esc(slug)}" title="${esc(darija)}">${esc(label)} <span>${n}</span></button>`
  ).join("");
  el.onclick = (e) => {
    const b = e.target.closest("button[data-cat]");
    if (!b) return;
    state.cat = b.dataset.cat;
    onPick(state.cat);
  };
}

export function matchCategory(state, value) {
  if (!state.cat) return true;
  if (state.cat === "__none") return !value;
  return value === state.cat;
}

// ---------- Badges d'audit IA ----------
export function auditBadges(score, validatedSource) {
  let html = "";
  if (score !== null && score !== undefined && !isNaN(score)) {
    const s = Number(score);
    const c = s >= 90 ? "g" : s >= 70 ? "y" : "r";
    html += `<span class="audit audit-${c}" title="Score de l'audit scientifique IA">Audit ${s}<small>/100</small></span>`;
  }
  if (validatedSource === "audit_ia") {
    html += ` <span class="audit-ok" title="L'audit IA a vérifié cet élément (note ≥ 95). La validation finale reste humaine.">✓ Vérifié par l’audit IA</span>`;
  }
  return html;
}

// =====================================================================
// Protocole de recherche v1 : niveaux de preuve, statuts, cuisson, nutriments
// =====================================================================
export const LEVELS = {
  1: ["S1", "Analyse de laboratoire"],
  2: ["S2", "Source primaire officielle (étiquette vérifiée, TMCA, CIQUAL, USDA)"],
  3: ["S3", "Fabricant ou publication"],
  4: ["S4", "Base collaborative (Open Food Facts)"],
  5: ["S5", "Estimation IA"],
};
export function levelBadge(level) {
  const l = Number(level);
  if (!LEVELS[l]) return `<span class="lvl lvl-x" title="Niveau de preuve inconnu">S?</span>`;
  return `<span class="lvl lvl-${l}" title="${esc(LEVELS[l][1])}">${LEVELS[l][0]}</span>`;
}

// Statuts : brouillon (a_valider) → vérifié (audit IA) → validé (audit humain) → référence (S1)
export function statusBadge(status, level) {
  if (status === "valide" && Number(level) === 1) return `<span class="st st-ref" title="Validé + analyse de laboratoire">Référence</span>`;
  const map = {
    draft: ["Brouillon", "st-draft"], a_valider: ["Brouillon", "st-draft"],
    verifie: ["Vérifié (audit IA)", "st-ver"], valide: ["Validé (audit humain)", "st-val"], rejete: ["Rejeté", "st-rej"],
  };
  const [t, c] = map[status] || [status || "?", "st-draft"];
  return `<span class="st ${c}">${esc(t)}</span>`;
}

export const COOKING_METHODS = [
  ["", "— non précisé —"],
  ["cru", "Cru (pas de cuisson)"],
  ["bouilli_peu_eau", "Bouilli, peu d'eau, égoutté"],
  ["bouilli_egoutte", "Bouilli, couvert d'eau, égoutté"],
  ["bouilli_eau_gardee", "Bouilli, eau gardée (absorbée ou mangée)"],
  ["mijote", "Mijoté"],
  ["revenu_mijote", "Revenu puis mijoté (tajine)"],
  ["braise", "Braisé"],
  ["frit", "Frit"],
  ["four", "Au four"],
  ["vapeur", "Vapeur (couscous)"],
  ["grille", "Grillé"],
];
export const methodName = (m) => (COOKING_METHODS.find(([k]) => k === (m || "")) || [m, m || "non précisé"])[1];

export const RETENTION_GROUPS = {
  legumes_feuilles: "Légumes feuilles", legumes_racines: "Légumes racines", legumes_autres: "Autres légumes",
  legumineuses: "Légumineuses", cereales_pates: "Pâtes, semoule", riz: "Riz", cereales_bouillie: "Céréales en bouillie",
  viande_boeuf: "Bœuf", viande_agneau: "Agneau", volaille: "Volaille", poisson: "Poisson", oeufs: "Œufs",
  pommes_de_terre: "Pommes de terre", laitiers: "Produits laitiers", fruits: "Fruits", autre: "Autre",
};

export const MICROS = [
  ["vit_c_mg", "Vitamine C", "mg"], ["thiamin_mg", "Vitamine B1 (thiamine)", "mg"], ["riboflavin_mg", "Vitamine B2 (riboflavine)", "mg"],
  ["niacin_mg", "Vitamine B3 (niacine)", "mg"], ["vit_b6_mg", "Vitamine B6", "mg"], ["folate_ug", "Folates (B9)", "µg"],
  ["vit_b12_ug", "Vitamine B12", "µg"], ["vit_a_ug", "Vitamine A (ER)", "µg"], ["vit_e_mg", "Vitamine E", "mg"],
  ["vit_d_ug", "Vitamine D", "µg"], ["iron_mg", "Fer", "mg"], ["calcium_mg", "Calcium", "mg"],
  ["magnesium_mg", "Magnésium", "mg"], ["zinc_mg", "Zinc", "mg"], ["potassium_mg", "Potassium", "mg"],
];

// Nav publique (jury, sans connexion)
export function publicNav(active) {
  const items = [["jury.html", "Preuves scientifiques"], ["methodologie.html", "Méthodologie"]];
  return `<nav class="side">
    <div class="brand">NutriX Data</div>
    <div class="muted" style="color:#cfe0d6;margin:-12px 0 12px">Base marocaine de composition des aliments</div>
    ${items.map(([href, label]) => `<a href="${href}" class="${href === active ? "on" : ""}">${label}</a>`).join("")}
    <a href="index.html" style="margin-top:auto">Espace équipe</a>
  </nav>`;
}

// Session facultative : renvoie le membre si connecté, sinon null (sans redirection)
export async function optionalMember() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return null;
  const { data: m } = await sb.from("team_members").select("role, full_name").eq("user_id", session.user.id).maybeSingle();
  return m ? { user: session.user, role: m.role, name: m.full_name } : null;
}
