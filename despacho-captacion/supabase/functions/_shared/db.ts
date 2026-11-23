import postgres from "npm:postgres@3.4.5";

let _sql: ReturnType<typeof postgres> | null = null;

/** Conexión directa a Postgres (SUPABASE_DB_URL la inyecta Supabase en las Edge Functions). */
export function db() {
  if (!_sql) {
    const url = Deno.env.get("SUPABASE_DB_URL");
    if (!url) throw new Error("Falta SUPABASE_DB_URL");
    _sql = postgres(url, { prepare: false, max: 3, idle_timeout: 20, connection: { search_path: "despacho" } });
  }
  return _sql;
}

export type Sql = ReturnType<typeof postgres>;
