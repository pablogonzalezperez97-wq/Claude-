import type { Sql } from "../_shared/db.ts";
import { json } from "../_shared/http.ts";

export type VerificarUsuario = (token: string) => Promise<string | null>;

/** Verifica el JWT contra Supabase Auth y devuelve el id de usuario. */
export const verificarConSupabase: VerificarUsuario = async (token) => {
  const url = Deno.env.get("SUPABASE_URL"), anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !anon) return null;
  const r = await fetch(`${url}/auth/v1/user`, { headers: { apikey: anon, Authorization: `Bearer ${token}` } });
  if (!r.ok) return null;
  const u = await r.json();
  return typeof u?.id === "string" ? u.id : null;
};

const ERRORES: Record<string, number> = {
  no_autorizado: 403, conflictos_sin_resolver: 409, lead_no_revisable: 409,
  conflicto_no_encontrado: 404, decision_no_valida: 422, estado_no_valido: 422, falta_destinatario: 422,
};

export function crearHandlerPanel(sql: () => Sql, verificar: VerificarUsuario = verificarConSupabase) {
  return async function handler(req: Request): Promise<Response> {
    if (req.method === "OPTIONS") return json(req, null, 204);

    const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const uid = token ? await verificar(token) : null;
    if (!uid) return json(req, { error: "no_autenticado" }, 401);

    // deno-lint-ignore no-explicit-any
    let cuerpo: Record<string, any> = {};
    if (req.method === "POST") {
      try { cuerpo = await req.json(); } catch { return json(req, { error: "json_invalido" }, 400); }
    } else if (req.method !== "GET") return json(req, { error: "metodo_no_permitido" }, 405);

    try {
      // Cada petición se ejecuta como el usuario autenticado: las políticas RLS deciden qué ve.
      const resultado = await sql().begin(async (tx) => {
        await tx`select set_config('request.jwt.claim.sub', ${uid}, true),
                        set_config('request.jwt.claims', ${JSON.stringify({ sub: uid, role: "authenticated" })}, true)`;
        await tx`set local role authenticated`;
        const [{ abogado }] = await tx`select despacho.es_abogado() as abogado`;
        if (!abogado) throw new Error("no_autorizado");

        if (req.method === "GET") {
          const [f] = await tx`select despacho.panel_pendientes() as p, despacho.panel_derivaciones() as d`;
          return { pendientes: f.p, derivaciones: f.d };
        }
        switch (cuerpo.accion) {
          case "decidir_lead": {
            const [f] = await tx`select despacho.decidir_lead(${cuerpo.lead_id}::uuid, ${cuerpo.decision}, ${cuerpo.nota ?? null}) as e`;
            return { ok: true, estado: f.e };
          }
          case "decidir_conflicto": {
            await tx`select despacho.decidir_conflicto(${cuerpo.conflicto_id}::uuid, ${cuerpo.estado}::despacho.estado_conflicto, ${cuerpo.nota ?? null})`;
            return { ok: true };
          }
          case "marcar_reenviado": {
            const ids = Array.isArray(cuerpo.lead_ids) ? cuerpo.lead_ids : [];
            const [f] = await tx`select despacho.marcar_reenviado(${ids}::uuid[], ${cuerpo.destinatario ?? ""}, ${cuerpo.nota ?? null}) as n`;
            return { ok: true, reenviados: f.n };
          }
          default: throw new Error("decision_no_valida");
        }
      });
      return json(req, resultado);
    } catch (e) {
      const codigo = (e as { message?: string }).message ?? "";
      if (ERRORES[codigo]) return json(req, { error: codigo }, ERRORES[codigo]);
      if (/invalid input (syntax|value)/.test(codigo)) return json(req, { error: "datos_invalidos" }, 422);
      console.error("panel_error", codigo);
      return json(req, { error: "error_interno" }, 500);
    }
  };
}
