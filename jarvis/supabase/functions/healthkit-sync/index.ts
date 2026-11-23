/**
 * healthkit-sync — v1
 * Recibe de la app JARVIS los agregados diarios, noches y entrenos leídos de
 * HealthKit y los escribe en las mismas tablas que apple-health-ingest, con la
 * misma nota de sueño y el mismo TRIMP. Sustituye a Health Auto Export.
 * Autenticación: JWT del propietario (no hay secreto dentro de la app).
 */
import { json, cors, requireOwner } from "../_shared/auth.ts";
import { round2, sleepScore, trimp, workoutType } from "../_shared/metrics.ts";

const HR_MAX = Number(Deno.env.get("USER_HR_MAX") ?? "190");
const HR_REST = Number(Deno.env.get("USER_HR_REST") ?? "45");

// columnas de daily_metrics que la app puede escribir
const DAILY_COLS = new Set([
  "hrv", "rhr", "weight_kg", "steps", "active_kcal", "vo2max", "respiratory_rate", "spo2",
  "wrist_temp_c", "hr_avg", "hr_min", "hr_max", "cardio_recovery", "exercise_min", "basal_kcal",
  "distance_km", "flights", "body_fat_pct", "lean_mass_kg", "daylight_min", "mindful_min",
  "caffeine_mg", "dietary_kcal", "protein_g", "carbs_g", "fat_g", "water_ml", "stand_hours",
  "breathing_disturbances", "walking_hr_avg", "physical_effort",
]);
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

interface Payload {
  days?: { date: string; metrics: Record<string, number> }[];
  sleep?: {
    date: string; deep_min?: number; rem_min?: number; core_min?: number; awake_min?: number;
    in_bed_min?: number; asleep_min?: number; sleep_start?: string; sleep_end?: string;
  }[];
  workouts?: {
    id: string; start: string; end?: string; name?: string; duration_min?: number;
    avg_hr?: number; max_hr?: number; active_kcal?: number; distance_km?: number;
    elevation_m?: number; is_indoor?: boolean;
  }[];
}

const num = (v: unknown) => (typeof v === "number" && isFinite(v) ? v : null);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  const db = await requireOwner(req);
  if (db instanceof Response) return db;

  let body: Payload;
  try { body = await req.json(); } catch { return json({ error: "invalid json" }, 400); }
  const now = new Date().toISOString();
  const errors: string[] = [];

  // ── días ─────────────────────────────────────────────────────────
  const dailyRows = (body.days ?? []).filter((d) => DATE_RE.test(d.date)).map((d) => {
    const row: Record<string, unknown> = { date: d.date, source: "healthkit", updated_at: now };
    for (const [k, v] of Object.entries(d.metrics ?? {})) {
      if (DAILY_COLS.has(k) && num(v) !== null) row[k] = round2(v);
    }
    return row;
  });

  // ── noches ───────────────────────────────────────────────────────
  const sleepRows = (body.sleep ?? []).filter((s) => DATE_RE.test(s.date)).map((s) => {
    const deep = Math.round(s.deep_min ?? 0), rem = Math.round(s.rem_min ?? 0);
    const core = Math.round(s.core_min ?? 0), awake = Math.round(s.awake_min ?? 0);
    const phases = deep + rem + core;
    const dur = phases > 0 ? phases : Math.round(s.asleep_min ?? 0);
    return {
      date: s.date, duration_min: dur, deep_min: deep, rem_min: rem, core_min: core, awake_min: awake,
      in_bed_min: Math.round(s.in_bed_min ?? 0) || dur + awake,
      sleep_start: s.sleep_start ?? null, sleep_end: s.sleep_end ?? null,
      sleep_score: sleepScore(dur, deep, rem, awake), source: "healthkit", updated_at: now,
    };
  });

  // ── entrenos ─────────────────────────────────────────────────────
  const workoutRows = (body.workouts ?? []).filter((w) => w.id && w.start).map((w) => {
    const dur = num(w.duration_min), avg = num(w.avg_hr);
    return {
      hae_id: "hk:" + w.id,
      date: w.start.slice(0, 10),
      type: workoutType(w.name ?? null),
      name: w.name ?? null,
      duration_min: dur !== null ? Math.round(dur) : null,
      load: trimp(dur, avg, HR_MAX, HR_REST),
      avg_hr: avg, max_hr: num(w.max_hr),
      active_kcal: num(w.active_kcal) !== null ? round2(w.active_kcal!) : null,
      distance_km: num(w.distance_km) !== null ? round2(w.distance_km!) : null,
      elevation_m: num(w.elevation_m),
      is_indoor: typeof w.is_indoor === "boolean" ? w.is_indoor : null,
      start_time: w.start, end_time: w.end ?? null, source: "healthkit",
    };
  });

  if (dailyRows.length) {
    const { error } = await db.from("daily_metrics").upsert(dailyRows, { onConflict: "date" });
    if (error) errors.push("daily: " + error.message);
  }
  if (sleepRows.length) {
    const { error } = await db.from("sleep_logs").upsert(sleepRows, { onConflict: "date" });
    if (error) errors.push("sleep: " + error.message);
  }
  if (workoutRows.length) {
    const { error } = await db.from("workouts").upsert(workoutRows, { onConflict: "hae_id" });
    if (error) errors.push("workouts: " + error.message);
  }

  // strain del día = suma de cargas de todos sus entrenos (HealthKit + anteriores)
  const dates = [...new Set(workoutRows.map((w) => w.date))];
  if (dates.length && !errors.length) {
    const { data, error } = await db.from("workouts").select("date, load").in("date", dates);
    if (error) errors.push("strain: " + error.message);
    else {
      const sum = new Map<string, number>();
      for (const r of data ?? []) if (typeof r.load === "number") sum.set(r.date, (sum.get(r.date) ?? 0) + r.load);
      const rows = [...sum].map(([date, s]) => ({ date, strain: round2(s), updated_at: now }));
      if (rows.length) {
        const { error: e2 } = await db.from("daily_metrics").upsert(rows, { onConflict: "date" });
        if (e2) errors.push("strain: " + e2.message);
      }
    }
  }

  const stats = { days: dailyRows.length, nights: sleepRows.length, workouts: workoutRows.length, errors };
  await db.from("sync_log").insert({ source: "healthkit", stats });
  return json({ ok: !errors.length, ...stats }, errors.length ? 500 : 200);
});
