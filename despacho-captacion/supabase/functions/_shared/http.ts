const ORIGENES = (Deno.env.get("ORIGENES_PERMITIDOS") ?? "*").split(",").map((s) => s.trim());

export function cabecerasCors(req: Request): HeadersInit {
  const origen = req.headers.get("origin") ?? "";
  const permitido = ORIGENES.includes("*") ? "*" : (ORIGENES.includes(origen) ? origen : ORIGENES[0]);
  return {
    "Access-Control-Allow-Origin": permitido,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Vary": "Origin",
  };
}

export function json(req: Request, cuerpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { ...cabecerasCors(req), "Content-Type": "application/json; charset=utf-8" },
  });
}

export function ipCliente(req: Request): string | null {
  const xff = req.headers.get("x-forwarded-for");
  const ip = xff?.split(",")[0]?.trim();
  return ip && /^[0-9a-fA-F:.]+$/.test(ip) ? ip : null;
}
