/**
 * jarvis-ask — v1
 * Pregunta libre a JARVIS desde la app o desde Siri. Reúne el estado de hoy y
 * los últimos 14 días, y responde con Claude. La clave de la API vive solo aquí
 * (secreto ANTHROPIC_API_KEY de Supabase), nunca en el iPhone.
 */
import Anthropic from "npm:@anthropic-ai/sdk@^0.136.0";
import { json, cors, requireOwner } from "../_shared/auth.ts";
import { isoDaysAgo } from "../_shared/metrics.ts";

const client = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
const MODEL = Deno.env.get("JARVIS_MODEL") ?? "claude-opus-5-5";

const SYSTEM = `Eres JARVIS, el coordinador del entorno de control personal de Pablo (abogado en Madrid, entrenador de fútbol, entrena fuerza).
Coordinas a ARES (recuperación, carga y fuerza), AURA (nutrición), Ray (puente nutrición-entreno), MIDAS (finanzas y noticias), Donna (pedidos) y ULTRÓN (auditor adversarial).
Responde en español de España, directo y breve: la respuesta puede leerse en voz alta por Siri, así que sin markdown, sin listas largas y sin tablas.
Usa SOLO los datos del bloque DATOS. Si un dato falta o está desactualizado (mira "checks" y "freshness"), dilo antes de concluir nada.
Readiness: 0-100, 50 = su línea base de 60 días. TSB > 0 fresco; TSB < -15 fatiga relevante.
No diagnostiques ni des consejo médico; ante síntomas o valores anómalos persistentes, sugiere consultar a un profesional.
MIDAS informa, no recomienda: nunca digas comprar, vender ni predigas precios.`;

interface Msg { role: "user" | "assistant"; content: string }

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  const db = await requireOwner(req);
  if (db instanceof Response) return db;

  let body: { question?: string; history?: Msg[]; voice?: boolean };
  try { body = await req.json(); } catch { return json({ error: "invalid json" }, 400); }
  const question = (body.question ?? "").trim().slice(0, 2000);
  if (!question) return json({ error: "empty question" }, 400);

  // estado de hoy (misma vista que la app) + panel compacto de 14 días
  const todayRes = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/jarvis-today`, {
    headers: { authorization: req.headers.get("authorization")! },
  });
  const today = todayRes.ok ? await todayRes.json() : { error: "jarvis-today no disponible" };
  const [daily, sleep, workouts] = await Promise.all([
    db.from("daily_metrics").select("date, hrv, rhr, strain, steps, dietary_kcal, protein_g, weight_kg").gte("date", isoDaysAgo(14)).order("date"),
    db.from("sleep_logs").select("date, sleep_score, duration_min, deep_min, rem_min").gte("date", isoDaysAgo(14)).order("date"),
    db.from("workouts").select("date, type, name, duration_min, load, avg_hr").gte("date", isoDaysAgo(14)).order("date"),
  ]);

  const data = JSON.stringify({ today, daily14: daily.data, sleep14: sleep.data, workouts14: workouts.data });
  const history = (body.history ?? []).slice(-10).filter((m) => m && (m.role === "user" || m.role === "assistant") && m.content);

  try {
    // fallbacks "default": si el modelo declina, la API reintenta en otro modelo adecuado
    const params = {
      model: MODEL,
      max_tokens: 2000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      output_config: { effort: body.voice ? "low" : "medium" },
      system: SYSTEM,
      messages: [
        ...history,
        { role: "user", content: `DATOS (${new Date().toISOString()}):\n${data}\n\nPREGUNTA: ${question}` },
      ],
    };
    // deno-lint-ignore no-explicit-any
    const res = await client.beta.messages.create(params as any);
    if (res.stop_reason === "refusal") return json({ answer: "No puedo responder a eso.", refused: true });
    const answer = res.content.filter((b) => b.type === "text").map((b) => (b as { text: string }).text).join("\n").trim();
    return json({ answer, truncated: res.stop_reason === "max_tokens" });
  } catch (e) {
    if (e instanceof Anthropic.RateLimitError) return json({ error: "rate_limited" }, 429);
    if (e instanceof Anthropic.APIError) { console.error("claude:", e.status, e.message); return json({ error: "upstream" }, 502); }
    console.error("ask:", e);
    return json({ error: "internal" }, 500);
  }
});
