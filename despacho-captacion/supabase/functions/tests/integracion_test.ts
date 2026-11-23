// Requiere una base de PRUEBAS con las migraciones aplicadas: TEST_DB_URL=postgres://...
import { assert, assertEquals } from "jsr:@std/assert@1.0.8";
import postgres from "npm:postgres@3.4.5";
import { crearHandlerTriaje } from "../triaje/handler.ts";
import { crearHandlerPanel } from "../panel/handler.ts";

const url = Deno.env.get("TEST_DB_URL");
const sql = url ? postgres(url, { prepare: false, max: 2, onnotice: () => {} }) : null;
const ABOGADO = "99999999-9999-9999-9999-999999999999";
const INTRUSO = "11111111-1111-1111-1111-111111111111";
const verificar = (t: string) => Promise.resolve(t === "token-abogado" ? ABOGADO : t === "token-intruso" ? INTRUSO : null);

const triaje = sql ? crearHandlerTriaje(() => sql) : null;
const panel = sql ? crearHandlerPanel(() => sql, verificar) : null;
const post = (cuerpo: unknown, token?: string) =>
  new Request("http://x/", { method: "POST", body: JSON.stringify(cuerpo),
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) } });

const sufijo = crypto.randomUUID().slice(0, 6);
const solicitud = {
  tipo: "fisica", nombre: "Lucía Prueba", email: `lucia.${sufijo}@prueba.test`, materia: "mer_constitucion",
  descripcion: "Quiero constituir una sociedad limitada con dos socios.", acepta_privacidad: true, acepta_condiciones: true,
  contrapartes: [{ nombre: `Contraparte Única ${sufijo}` }],
};

Deno.test({ name: "flujo completo formulario → panel", ignore: !sql, sanitizeResources: false, sanitizeOps: false, fn: async () => {
  await sql!`insert into despacho.abogados values (${ABOGADO}, 'Abogado') on conflict do nothing`;

  // Catálogo
  const cat = await (await triaje!(new Request("http://x/"))).json();
  assertEquals(cat.materias.length, 19);

  // Validación
  const r422 = await triaje!(post({ ...solicitud, email: "malo" }));
  assertEquals(r422.status, 422);

  // Honeypot: responde OK sin guardar
  const antes = (await sql!`select count(*)::int n from despacho.leads`)[0].n;
  await triaje!(post({ ...solicitud, web: "http://spam" }));
  assertEquals((await sql!`select count(*)::int n from despacho.leads`)[0].n, antes);

  // Alta: 30 materia + 10 condiciones = 40 -> revisión
  const r = await (await triaje!(post(solicitud))).json();
  assertEquals(r.resultado, "en_revision");
  assert(r.referencia && !("puntuacion" in r));

  // Panel sin token / intruso / abogado
  assertEquals((await panel!(new Request("http://x/"))).status, 401);
  assertEquals((await panel!(new Request("http://x/", { headers: { authorization: "Bearer token-intruso" } }))).status, 403);
  const p = await (await panel!(new Request("http://x/", { headers: { authorization: "Bearer token-abogado" } }))).json();
  const mio = p.pendientes.find((x: { contacto: { email: string } }) => x.contacto.email === solicitud.email);
  assert(mio, "el abogado ve la solicitud");
  assert(Array.isArray(p.derivaciones), "incluye derivaciones");
  assert(mio.responder_antes, "incluye plazo de respuesta");

  // Derivación: mensaje con recursos de emergencia
  const der = await (await triaje!(post({ ...solicitud, email: `d.${sufijo}@prueba.test`, materia: "der_penal_detenido", contrapartes: [] }))).json();
  assertEquals(der.resultado, "derivar");
  assert(der.emergencia?.includes("016"));

  // Decisión
  const d = await (await panel!(post({ accion: "decidir_lead", lead_id: mio.id, decision: "aceptar", nota: "OK" }, "token-abogado"))).json();
  assertEquals(d.estado, "apto");
  const d2 = await panel!(post({ accion: "decidir_lead", lead_id: "no-es-uuid", decision: "aceptar" }, "token-abogado"));
  assertEquals(d2.status, 422);

  await sql!.end();
}});
