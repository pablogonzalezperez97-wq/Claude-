// Edge Function pública: catálogo de materias (GET) y alta de consultas (POST).
// Desplegar con verify_jwt = false (ver supabase/config.toml).
import { db } from "../_shared/db.ts";
import { crearHandlerTriaje } from "./handler.ts";

Deno.serve(crearHandlerTriaje(db));
