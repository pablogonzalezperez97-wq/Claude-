// Servidor de desarrollo: sirve web/ y enruta /functions/v1/* a los handlers reales contra una base local.
// Uso: TEST_DB_URL=postgres://postgres@localhost:5433/t deno run -A herramientas/servidor_local.ts
import postgres from "npm:postgres@3.4.5";
import { crearHandlerTriaje } from "../supabase/functions/triaje/handler.ts";
import { crearHandlerPanel } from "../supabase/functions/panel/handler.ts";

const sql = postgres(Deno.env.get("TEST_DB_URL")!, { prepare: false, max: 3, onnotice: () => {} });
const triaje = crearHandlerTriaje(() => sql);
// En local, el token "dev-abogado" equivale al usuario abogado de pruebas.
const panel = crearHandlerPanel(() => sql, (t) => Promise.resolve(t === "dev-abogado" ? "99999999-9999-9999-9999-999999999999" : null));
const raiz = new URL("../web/", import.meta.url);
const TIPOS: Record<string, string> = { html: "text/html; charset=utf-8", css: "text/css", js: "text/javascript" };

Deno.serve({ port: Number(Deno.env.get("PUERTO") ?? 8787) }, async (req) => {
  const { pathname } = new URL(req.url);
  if (pathname.startsWith("/functions/v1/triaje")) return triaje(req);
  if (pathname.startsWith("/functions/v1/panel")) return panel(req);
  const ruta = pathname === "/" ? "consulta.html" : pathname.slice(1);
  if (ruta.includes("..")) return new Response("No", { status: 400 });
  try {
    const cuerpo = await Deno.readFile(new URL(ruta, raiz));
    return new Response(cuerpo, { headers: { "content-type": TIPOS[ruta.split(".").pop()!] ?? "application/octet-stream" } });
  } catch { return new Response("No encontrado", { status: 404 }); }
});
