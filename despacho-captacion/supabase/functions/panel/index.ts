// Edge Function privada del abogado: bandeja de revisión y decisiones.
// La autenticación se comprueba dentro (token de Supabase Auth + tabla despacho.abogados).
import { db } from "../_shared/db.ts";
import { crearHandlerPanel } from "./handler.ts";

Deno.serve(crearHandlerPanel(db));
