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
    ["a-valider.html", "À valider"],
    ["valides.html", "Validés"],
    ["produits.html", "Produits"],
  ];
  return `<nav class="side">
    <div class="brand">NutriX Data</div>
    ${items.map(([href, label]) =>
      `<a href="${href}" class="${href === active ? "on" : ""}">${label}</a>`).join("")}
    <button id="logout" class="link">Se déconnecter</button>
  </nav>`;
}

export function wireLogout() {
  document.getElementById("logout")?.addEventListener("click", async () => {
    await sb.auth.signOut();
    location.href = "index.html";
  });
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
