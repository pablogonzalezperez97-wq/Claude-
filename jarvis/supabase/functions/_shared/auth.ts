// Acceso de la app: sesión de Supabase Auth del propietario. Las funciones
// verifican el JWT y que el usuario sea el propietario antes de usar service_role.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

export const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, content-type, apikey, x-client-info",
  "access-control-allow-methods": "GET, POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "content-type": "application/json" },
  });
}

export function admin(): SupabaseClient {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
}

/** Devuelve el cliente de servicio si quien llama es el propietario; si no, una respuesta de error. */
export async function requireOwner(req: Request): Promise<SupabaseClient | Response> {
  const auth = req.headers.get("authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);
  const asUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
  const { data, error } = await asUser.rpc("is_owner");
  if (error || data !== true) return json({ error: "forbidden" }, 403);
  return admin();
}
