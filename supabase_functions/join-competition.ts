// Supabase Edge Function: join-competition
// Deploy with SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY configured as function secrets.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...cors, "Content-Type": "application/json" },
});
async function sha256(s: string) {
  const data = new TextEncoder().encode(s.trim());
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map(x => x.toString(16).padStart(2, "0")).join("");
}
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const authHeader = req.headers.get("Authorization") || "";
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData.user) return reply({ error: "Anonymous sign-in required" }, 401);
  let body: { competition_slug?: string; code?: string };
  try { body = await req.json(); } catch { return reply({ error: "Invalid JSON" }, 400); }
  const slug = String(body.competition_slug || "nova-arena");
  const code = String(body.code || "").trim();
  if (code.length < 6 || code.length > 120) return reply({ error: "Invalid team code" }, 400);
  const admin = createClient(url, serviceKey);
  const { data: row, error } = await admin.from("team_join_codes")
    .select("team_id,team_name,code_hash").eq("competition_slug", slug).eq("active", true)
    .eq("code_hash", await sha256(code)).maybeSingle();
  if (error || !row) return reply({ error: "رمز الفريق غير صحيح أو غير مفعّل" }, 403);
  const { error: upsertErr } = await admin.from("participant_sessions").upsert({
    user_id: userData.user.id, competition_slug: slug, team_id: row.team_id, team_name: row.team_name, active: true
  });
  if (upsertErr) return reply({ error: "Could not create participant session" }, 500);
  return reply({ team_id: row.team_id, team_name: row.team_name });
});
