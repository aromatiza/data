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
