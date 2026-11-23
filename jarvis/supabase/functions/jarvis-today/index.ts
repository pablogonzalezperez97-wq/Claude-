/**
 * jarvis-today — v1
 * Una sola llamada con todo lo que la app y los widgets muestran hoy:
 * readiness compuesto, sueño, carga, nutrición, MIDAS, Donna, alertas abiertas
 * y comprobaciones de frescura (ULTRÓN). Solo lectura.
 */
import { json, cors, requireOwner } from "../_shared/auth.ts";
import { compositeReadiness, isoDaysAgo, rowZ, trainingLoad } from "../_shared/metrics.ts";

const HOURS = 3600_000;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  const db = await requireOwner(req);
  if (db instanceof Response) return db;

  try {
    const since = isoDaysAgo(100);
    const [daily, sleep, meals, editions, orders, alerts, syncs] = await Promise.all([
      db.from("daily_metrics").select("*").gte("date", since).order("date"),
      db.from("sleep_logs").select("*").gte("date", since).order("date"),
      db.from("aura_meals").select("date, kcal, protein_g, carbs_g, fat_g").gte("date", isoDaysAgo(7)),
      db.from("midas_editions").select("id, date, kind, generated_at, stories").order("generated_at", { ascending: false }).limit(3),
      db.from("donna_orders").select("*").not("status", "in", "(entregado,devuelto,cancelado)"),
      db.from("alerts").select("id, agent, level, text, ref, created_at").is("resolved_at", null).order("created_at", { ascending: false }).limit(10),
      db.from("sync_log").select("source, received_at").eq("source", "healthkit").order("received_at", { ascending: false }).limit(1),
    ]);
    for (const r of [daily, sleep, meals, editions, orders, alerts, syncs]) if (r.error) throw new Error(r.error.message);

    const d = daily.data ?? [], s = sleep.data ?? [];
    const sleepByDate = new Map(s.map((x) => [x.date as string, x]));
    const i = d.length - 1;
    const last = i >= 0 ? d[i] : null;
    const z = i >= 0 ? rowZ(d, i, sleepByDate) : null;
    const lastSleep = s.length ? s[s.length - 1] : null;

    const strain = new Map<string, number>();
    for (const r of d) if (typeof r.strain === "number") strain.set(r.date, r.strain);
    const load = trainingLoad(strain, 90);

    // nutrición de hoy por foto (AURA) + lo que llega de Apple Health
    const today = new Date().toISOString().slice(0, 10);
    const todayMeals = (meals.data ?? []).filter((m) => m.date === today);
    const sum = (k: "kcal" | "protein_g" | "carbs_g" | "fat_g") => todayMeals.reduce((a, m) => a + (Number(m[k]) || 0), 0);

    // MIDAS: portada de la última edición
    const ed = editions.data?.[0];
    const front = ((ed?.stories ?? []) as Record<string, unknown>[]).filter((x) => x.front)
      .map((x) => ({ id: x.id, headline: x.headline, category: x.category, summary: x.summary }));

    // ULTRÓN: frescura y cobertura
    const checks: { level: string; text: string }[] = [];
    const lastDataAt = last?.updated_at ? Date.parse(last.updated_at as string) : 0;
    const staleH = lastDataAt ? (Date.now() - lastDataAt) / HOURS : Infinity;
    if (staleH > 36) checks.push({ level: staleH > 96 ? "critical" : "warn",
      text: lastDataAt ? `Sin datos de salud nuevos desde hace ${Math.round(staleH / 24)} días.` : "No hay datos de salud." });
    if (last && last.hrv == null) checks.push({ level: "info", text: "Falta la HRV del último día: el readiness se ha calculado sin ella." });
    if (lastSleep && lastSleep.date !== last?.date) checks.push({ level: "info", text: "La última noche y el último día no coinciden." });

    return json({
      generated_at: new Date().toISOString(),
      date: last?.date ?? null,
      readiness: z ? compositeReadiness(z) : null,
      z,
      vitals: last ? { hrv: last.hrv, rhr: last.rhr, steps: last.steps, active_kcal: last.active_kcal, weight_kg: last.weight_kg } : null,
      sleep: lastSleep ? {
        date: lastSleep.date, score: lastSleep.sleep_score, duration_min: lastSleep.duration_min,
        deep_min: lastSleep.deep_min, rem_min: lastSleep.rem_min, awake_min: lastSleep.awake_min,
        start: lastSleep.sleep_start, end: lastSleep.sleep_end,
      } : null,
      load: load[load.length - 1],
      load_series: load.slice(-28),
      nutrition: {
        photo: { kcal: sum("kcal"), protein_g: sum("protein_g"), carbs_g: sum("carbs_g"), fat_g: sum("fat_g"), meals: todayMeals.length },
        health: last ? { kcal: last.dietary_kcal, protein_g: last.protein_g, carbs_g: last.carbs_g, fat_g: last.fat_g } : null,
      },
      midas: ed ? { edition: ed.id, generated_at: ed.generated_at, front } : null,
      donna: { active: orders.data ?? [] },
      alerts: alerts.data ?? [],
      freshness: { last_health_update: last?.updated_at ?? null, last_healthkit_sync: syncs.data?.[0]?.received_at ?? null },
      checks,
    });
  } catch (e) {
    console.error("today:", e);
    return json({ error: "internal" }, 500);
  }
});
