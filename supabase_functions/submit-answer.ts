// Supabase Edge Function: submit-answer
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...cors, "Content-Type": "application/json" },
});
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const authHeader = req.headers.get("Authorization") || "";
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData.user) return reply({ error: "Join the competition first" }, 401);
  let body: { competition_slug?: string; question_id?: string; answer_index?: number };
  try { body = await req.json(); } catch { return reply({ error: "Invalid JSON" }, 400); }
  const slug = String(body.competition_slug || "nova-arena");
  const questionId = String(body.question_id || "");
  const answerIndex = Number(body.answer_index);
  if (!questionId || !Number.isInteger(answerIndex) || answerIndex < 0 || answerIndex > 7) return reply({ error: "Invalid answer" }, 400);
  const admin = createClient(url, serviceKey);
  const { data: session, error: sessionErr } = await admin.from("participant_sessions")
    .select("team_id,team_name,active,competition_slug").eq("user_id", userData.user.id).eq("competition_slug", slug).eq("active", true).maybeSingle();
  if (sessionErr || !session) return reply({ error: "No active team session" }, 403);
  const { data: pub, error: pubErr } = await admin.from("competition_publications")
    .select("published_payload").eq("competition_slug", slug).maybeSingle();
  if (pubErr || !pub) return reply({ error: "Competition is not published" }, 404);
  const payload = pub.published_payload as any;
  const currentIndex = Number(payload?.session?.currentQ || 0);
  const currentQuestion = payload?.questions?.[currentIndex];
  if (!currentQuestion || String(currentQuestion.id) !== questionId) return reply({ error: "This question is no longer active" }, 409);
  if (!payload?.session?.running) return reply({ error: "The round is not accepting answers" }, 409);
  const { error: insertErr } = await admin.from("answer_submissions").insert({
    competition_slug: slug, participant_id: userData.user.id, team_id: session.team_id,
    question_id: questionId, answer_index: answerIndex
  });
  if (insertErr) {
    if (insertErr.code === "23505") return reply({ error: "You already submitted an answer for this question" }, 409);
    return reply({ error: "Could not submit answer" }, 500);
  }
  return reply({ accepted: true, team_name: session.team_name });
});
