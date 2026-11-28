// Pruebas de las operaciones de gestión del panel. Requiere TEST_DB_URL con las migraciones aplicadas.
import { assert, assertEquals } from "jsr:@std/assert@1.0.8";
import postgres from "npm:postgres@3.4.5";
import { crearHandlerPanel } from "../panel/handler.ts";

const url = Deno.env.get("TEST_DB_URL");
const sql = url ? postgres(url, { prepare: false, max: 2, onnotice: () => {} }) : null;
const ABOGADO = "99999999-9999-9999-9999-999999999999";
const panel = sql ? crearHandlerPanel(() => sql, (t) => Promise.resolve(t === "tok" ? ABOGADO : null)) : null;
const llamar = async (cuerpo: unknown) => {
  const r = await panel!(new Request("http://x/", { method: "POST", body: JSON.stringify(cuerpo),
    headers: { "content-type": "application/json", authorization: "Bearer tok" } }));
  return { status: r.status, datos: await r.json() };
};

Deno.test({ name: "gestión: expediente, tareas, agenda, finanzas, oportunidades", ignore: !sql, sanitizeResources: false, sanitizeOps: false, fn: async () => {
  await sql!`insert into despacho.abogados values (${ABOGADO}, 'Abogado') on conflict do nothing`;
  const suf = crypto.randomUUID().slice(0, 6);
  const [cl] = await sql!`insert into despacho.clientes (tipo, nombre, email) values ('juridica', ${"Delta " + suf}, 'd@x.test') returning id`;
  const [ld] = await sql!`insert into despacho.leads (cliente_id, materia_codigo, estado) values (${cl.id}, 'mer_contratos', 'apto') returning id`;
  await sql!`insert into despacho.oportunidades (lead_id, materia_codigo, necesidad, evidencia, confianza)
             values (${ld.id}, 'mer_deudas', 'Facturas impagadas de clientes', '"tenemos tres clientes que no pagan"', 0.7)`;

  const ab = await llamar({ accion: "abrir_expediente", lead_id: ld.id, titulo: `Delta ${suf} · contrato distribución`, honorarios: 1200 });
  assertEquals(ab.status, 200);
  const exp = ab.datos.id;

  assertEquals((await llamar({ accion: "actualizar_expediente", id: exp, estado: "en_tramite", notas_internas: "Prioridad alta", hoja_encargo_firmada: true })).status, 200);
  assertEquals((await llamar({ accion: "actualizar_expediente", id: exp, estado: "inventado" })).status, 422);

  assertEquals((await llamar({ accion: "crear_tarea", expediente_id: exp, titulo: "Revisar cláusula de exclusividad", vence_en: "2026-12-02" })).status, 200);
  assertEquals((await llamar({ accion: "crear_evento", expediente_id: exp, tipo: "vencimiento", titulo: "Plazo alegaciones", inicio: "2026-12-03T10:00:00+01:00" })).status, 200);
  assertEquals((await llamar({ accion: "crear_evento", tipo: "cita_cliente", titulo: "x", inicio: "2026-12-03T10:00:00+01:00" })).status, 422, "citas solo desde el embudo");
  const mv = await llamar({ accion: "crear_movimiento", expediente_id: exp, tipo: "honorario", concepto: "Primer pago", base_eur: 600 });
  assertEquals(Number(mv.datos.total_eur), 726);
  const sup = await llamar({ accion: "crear_movimiento", expediente_id: exp, tipo: "suplido", concepto: "Notaría", base_eur: 80, estado: "pagado" });
  assertEquals(Number(sup.datos.total_eur), 80, "suplido sin IVA por defecto");

  const detR = await llamar({ accion: "detalle_expediente", id: exp });
  assertEquals(detR.status, 200);
  const det = detR.datos;
  assertEquals(det.estado, "en_tramite");
  assertEquals(det.notas_internas, "Prioridad alta");
  assertEquals(det.tareas.length, 1);
  assertEquals(det.movimientos.length, 2);
  assertEquals(det.oportunidades.length, 1, "la oportunidad del lead pasa al expediente");

  const lista = (await llamar({ accion: "listar_expedientes" })).datos;
  const fila = lista.find((x: { id: string }) => x.id === exp);
  assertEquals(Number(fila.pendiente_cobro), 726);

  const ag = (await llamar({ accion: "listar_agenda", desde: "2026-12-01", hasta: "2026-12-31" })).datos;
  assert(ag.eventos.some((e: { titulo: string }) => e.titulo === "Plazo alegaciones"));
  assert(ag.festivos.some((f: { fecha: string }) => f.fecha === "2026-12-08"), "festivos de La Rioja");

  const fin = (await llamar({ accion: "listar_finanzas" })).datos;
  assert(Number(fin.totales.pendiente) >= 726);

  await llamar({ accion: "marcar_movimiento", id: mv.datos.id, estado: "cobrado" });
  const op = (await llamar({ accion: "listar_oportunidades" })).datos.find((o: { necesidad: string }) => o.necesidad.startsWith("Facturas"));
  assertEquals((await llamar({ accion: "decidir_oportunidad", id: op.id, estado: "validada" })).status, 200);

  const dash = (await llamar({ accion: "dashboard" })).datos;
  assert(Number(dash.expedientes_activos) >= 1 && Array.isArray(dash.proximos));

  assertEquals((await llamar({ accion: "constructor" })).status, 422, "no expone el prototipo");
  assertEquals((await llamar({ accion: "detalle_expediente", id: "no-uuid" })).status, 422);
  await sql!.end();
}});
