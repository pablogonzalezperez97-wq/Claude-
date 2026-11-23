// Cálculos de JARVIS compartidos por las funciones. Misma lógica que Jarvis-mcp v3
// y apple-health-ingest v4.1, para que la app, el Hub y los agentes vean el mismo número.

export const round1 = (x: number) => Math.round(x * 10) / 10;
export const round2 = (x: number) => Math.round(x * 100) / 100;
export const clamp = (x: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, x));
export const nums = (xs: unknown[]) => xs.filter((v) => typeof v === "number" && isFinite(v)) as number[];
export const mean = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;

export function stdev(xs: number[], m: number): number {
  if (xs.length < 2) return 0;
  return Math.sqrt(xs.reduce((a, b) => a + (b - m) ** 2, 0) / (xs.length - 1));
}

export function zScore(x: number, w: number[]): number | null {
  if (w.length < 5) return null;
  const m = mean(w), sd = stdev(w, m);
  if (sd < 1e-9) return null;
  return round1((x - m) / sd);
}

export function isoDaysAgo(days: number, from = new Date()): string {
  const d = new Date(from);
  d.setUTCDate(d.getUTCDate() - days);
  return d.toISOString().slice(0, 10);
}

export interface Z { hrv: number | null; rhr: number | null; sleep: number | null; temp: number | null; resp: number | null }

// readiness 0-100; 50 = en baseline (HRV .35, RHR .25, sueño .25, temp .10, resp .05)
export function compositeReadiness(z: Z): number | null {
  const parts: { w: number; v: number }[] = [];
  if (z.hrv !== null) parts.push({ w: 0.35, v: z.hrv });
  if (z.rhr !== null) parts.push({ w: 0.25, v: -z.rhr });
  if (z.sleep !== null) parts.push({ w: 0.25, v: z.sleep });
  if (z.temp !== null) parts.push({ w: 0.10, v: -z.temp });
  if (z.resp !== null) parts.push({ w: 0.05, v: -z.resp });
  if (!parts.length) return null;
  const wSum = parts.reduce((a, p) => a + p.w, 0);
  const s = parts.reduce((a, p) => a + (p.w / wSum) * p.v, 0);
  return Math.round(clamp(50 + 12 * s, 0, 100));
}

type Row = Record<string, unknown>;

export function rowZ(daily: Row[], i: number, sleepByDate: Map<string, Row>): Z {
  const r = daily[i];
  const prev = daily.slice(Math.max(0, i - 60), i);
  const w = (col: string) => nums(prev.map((p) => p[col]));
  const s = sleepByDate.get(r.date as string);
  const prevSleep = nums(prev.map((p) => sleepByDate.get(p.date as string)?.sleep_score));
  const n = (v: unknown) => (typeof v === "number" ? v : null);
  return {
    hrv: n(r.hrv) !== null ? zScore(r.hrv as number, w("hrv")) : null,
    rhr: n(r.rhr) !== null ? zScore(r.rhr as number, w("rhr")) : null,
    sleep: n(s?.sleep_score) !== null ? zScore(s!.sleep_score as number, prevSleep) : null,
    temp: n(r.wrist_temp_c) !== null ? zScore(r.wrist_temp_c as number, w("wrist_temp_c")) : null,
    resp: n(r.respiratory_rate) !== null ? zScore(r.respiratory_rate as number, w("respiratory_rate")) : null,
  };
}

// CTL 42 d, ATL 7 d, TSB = CTL − ATL. Días sin registro cuentan como 0.
export function trainingLoad(strainByDate: Map<string, number>, days = 90) {
  let ctl = 0, atl = 0;
  const series: { date: string; load: number; ctl: number; atl: number; tsb: number }[] = [];
  for (let i = days - 1; i >= 0; i--) {
    const date = isoDaysAgo(i);
    const load = strainByDate.get(date) ?? 0;
    ctl += (load - ctl) / 42;
    atl += (load - atl) / 7;
    series.push({ date, load, ctl: round1(ctl), atl: round1(atl), tsb: round1(ctl - atl) });
  }
  return series;
}

export function sleepScore(dur: number, deep: number, rem: number, awake: number): number | null {
  if (dur <= 0) return null;
  const d = Math.min(dur / 480, 1) * 50;
  const a = Math.min((deep + rem) / dur / 0.45, 1) * 30;
  const eff = dur / (dur + awake);
  const e = Math.min(Math.max((eff - 0.75) / 0.2, 0), 1) * 20;
  return Math.round(d + a + e);
}

// TRIMP de Banister (hombre); sin FC media, duración × 0,5.
export function trimp(durMin: number | null, avgHr: number | null, hrMax: number, hrRest: number): number | null {
  if (durMin === null) return null;
  if (avgHr !== null && hrMax > hrRest) {
    const x = clamp((avgHr - hrRest) / (hrMax - hrRest), 0, 1);
    return round2(durMin * x * 0.64 * Math.exp(1.92 * x));
  }
  return round2(durMin * 0.5);
}

export function workoutType(name: string | null): string {
  const n = (name ?? "").toLowerCase();
  if (/(run|carrera|correr)/.test(n)) return "carrera";
  if (/(strength|fuerza|functional|traditional|weight)/.test(n)) return "fuerza";
  if (/(walk|caminar|hik)/.test(n)) return "caminata";
  if (/(cycl|bici|bike)/.test(n)) return "ciclismo";
  return "otro";
}
