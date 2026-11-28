// Operaciones de gestión del despacho (vista del abogado).
// Se ejecutan dentro de la transacción del handler, como el usuario autenticado: RLS aplica siempre.
import type { Sql } from "../_shared/db.ts";

// deno-lint-ignore no-explicit-any
type Cuerpo = Record<string, any>;
// deno-lint-ignore no-explicit-any
type Tx = any;

const ESTADOS_EXP = ["abierto", "en_tramite", "pendiente_revision", "urgente", "suspendido", "cerrado"];
const TIPOS_EVENTO = ["vencimiento", "audiencia", "reunion", "cita_cliente", "recordatorio"];
const TIPOS_MOV = ["honorario", "provision_fondos", "suplido", "gasto"];
const ESTADOS_MOV = ["pendiente", "cobrado", "pagado", "anulado"];
const ESTADOS_OPORT = ["validada", "ofrecida", "aceptada", "descartada"];

const texto = (v: unknown, max = 500) => {
  if (typeof v !== "string" || !v.trim()) throw new Error("datos_invalidos");
  return v.trim().slice(0, max);
};
const opcional = (v: unknown, max = 500) => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null);
const numero = (v: unknown) => {
  const n = typeof v === "number" ? v : Number(v);
  if (!isFinite(n) || n < 0) throw new Error("datos_invalidos");
  return n;
};
const enLista = (v: unknown, lista: string[]) => {
  if (typeof v !== "string" || !lista.includes(v)) throw new Error("datos_invalidos");
  return v;
};

export const ACCIONES_GESTION: Record<string, (tx: Tx, c: Cuerpo) => Promise<unknown>> = {
  async dashboard(tx) {
    const [f] = await tx`select despacho.panel_dashboard() as d`;
    const proximos = await tx`
      select e.id, e.tipo, e.titulo, e.inicio, x.numero
      from despacho.eventos e left join despacho.expedientes x on x.id = e.expediente_id
      where not e.hecho and e.inicio < now() + interval '7 days' order by e.inicio limit 8`;
    return { ...f.d, proximos };
  },

  async listar_clientes(tx) {
    return await tx`
      select c.id, c.tipo, c.nombre, c.nif, c.email, c.telefono, c.user_id is not null as portal,
             (select count(*) from despacho.expedientes e where e.cliente_id = c.id and e.estado <> 'cerrado')::int as expedientes_activos
      from despacho.clientes c order by c.nombre`;
  },

  async listar_expedientes(tx, c) {
    const estado = c.estado && ESTADOS_EXP.includes(c.estado) ? c.estado : null;
    return await tx`
      select e.id, e.numero, e.titulo, e.estado, e.contraparte, e.organo, e.abierto_en, e.honorarios_pactados,
             cl.nombre as cliente, m.nombre as materia, m.area,
             (select min(ev.inicio) from despacho.eventos ev where ev.expediente_id = e.id and not ev.hecho and ev.inicio > now()) as proximo_evento,
             (select coalesce(sum(total_eur), 0) from despacho.movimientos mv where mv.expediente_id = e.id
                and mv.estado = 'pendiente' and mv.tipo in ('honorario', 'provision_fondos')) as pendiente_cobro
      from despacho.expedientes e
      join despacho.clientes cl on cl.id = e.cliente_id
      left join despacho.materias m on m.codigo = e.materia_codigo
      where (${estado}::text is null or e.estado::text = ${estado})
      order by (e.estado = 'cerrado'), e.abierto_en desc`;
  },

  async detalle_expediente(tx, c) {
    const id = texto(c.id, 40);
    const [exp] = await tx`
      select e.id, e.numero, e.titulo, e.estado, e.contraparte, e.organo, e.procedimiento, e.honorarios_pactados,
             e.hoja_encargo_firmada, e.pbc_diligencia_ok, e.abierto_en, e.cerrado_en, e.materia_codigo,
             despacho.notas_expediente(e.id) as notas_internas,
             jsonb_build_object('id', cl.id, 'nombre', cl.nombre, 'nif', cl.nif, 'email', cl.email, 'telefono', cl.telefono,
                                'portal', cl.user_id is not null) as cliente,
             m.nombre as materia
      from despacho.expedientes e join despacho.clientes cl on cl.id = e.cliente_id
      left join despacho.materias m on m.codigo = e.materia_codigo
      where e.id = ${id}::uuid`;
    if (!exp) throw new Error("no_encontrado");
    const [tareas, eventos, movimientos, documentos, mensajes, oportunidades] = await Promise.all([
      tx`select id, titulo, vence_en, hecha from despacho.tareas where expediente_id = ${id}::uuid order by hecha, vence_en nulls last`,
      tx`select id, tipo, titulo, inicio, fin, lugar, hecho from despacho.eventos where expediente_id = ${id}::uuid order by inicio`,
      tx`select id, tipo, concepto, base_eur, iva_pct, total_eur, estado, fecha, vence_en, factura_ref
         from despacho.movimientos where expediente_id = ${id}::uuid order by fecha desc`,
      tx`select id, nombre_original, categoria, revisado, visible_cliente, subido_por, subido_en
         from despacho.documentos where expediente_id = ${id}::uuid order by subido_en desc`,
      tx`select id, autor, texto, leido, creado_en from despacho.mensajes where expediente_id = ${id}::uuid order by creado_en`,
      tx`select o.id, o.necesidad, o.evidencia, o.confianza, o.estado, m.nombre as materia
         from despacho.oportunidades o left join despacho.materias m on m.codigo = o.materia_codigo
         where o.expediente_id = ${id}::uuid order by o.creado_en`,
    ]);
    // Al abrir el expediente, los mensajes del cliente quedan leídos.
    await tx`update despacho.mensajes set leido = true where expediente_id = ${id}::uuid and autor = 'cliente' and not leido`;
    return { ...exp, tareas, eventos, movimientos, documentos, mensajes, oportunidades };
  },

  async abrir_expediente(tx, c) {
    const [f] = await tx`select despacho.abrir_expediente(${texto(c.lead_id, 40)}::uuid, ${texto(c.titulo, 300)},
                                                          ${c.honorarios == null || c.honorarios === "" ? null : numero(c.honorarios)}) as id`;
    return { id: f.id };
  },

  async actualizar_expediente(tx, c) {
    const id = texto(c.id, 40);
    const cambios: Record<string, unknown> = {};
    if (c.estado !== undefined) cambios.estado = enLista(c.estado, ESTADOS_EXP);
    if (c.titulo !== undefined) cambios.titulo = texto(c.titulo, 300);
    for (const k of ["organo", "procedimiento", "contraparte"]) if (c[k] !== undefined) cambios[k] = opcional(c[k], 300);
    if (c.notas_internas !== undefined) cambios.notas_internas = opcional(c.notas_internas, 10000);
    if (c.honorarios_pactados !== undefined) cambios.honorarios_pactados = c.honorarios_pactados === null || c.honorarios_pactados === "" ? null : numero(c.honorarios_pactados);
    for (const k of ["hoja_encargo_firmada", "pbc_diligencia_ok"]) if (typeof c[k] === "boolean") cambios[k] = c[k];
    if (!Object.keys(cambios).length) throw new Error("datos_invalidos");
    if (cambios.estado === "cerrado") cambios.cerrado_en = new Date().toISOString().slice(0, 10);
    const r = await tx`update despacho.expedientes set ${tx(cambios)} where id = ${id}::uuid returning id`;
    if (!r.length) throw new Error("no_encontrado");
    return { ok: true };
  },

  async listar_tareas(tx, c) {
    return await tx`
      select t.id, t.titulo, t.vence_en, t.hecha, e.id as expediente_id, e.numero, e.titulo as expediente
      from despacho.tareas t left join despacho.expedientes e on e.id = t.expediente_id
      where ${c.todas === true} or not t.hecha
      order by t.hecha, t.vence_en nulls last`;
  },

  async crear_tarea(tx, c) {
    const [r] = await tx`insert into despacho.tareas (expediente_id, titulo, vence_en, responsable)
      values (${opcional(c.expediente_id, 40)}::uuid, ${texto(c.titulo, 300)}, ${opcional(c.vence_en, 10)}::date, auth.uid()) returning id`;
    return r;
  },

  async completar_tarea(tx, c) {
    const hecha = c.hecha !== false;
    await tx`update despacho.tareas set hecha = ${hecha}, hecha_en = case when ${hecha} then now() end where id = ${texto(c.id, 40)}::uuid`;
    return { ok: true };
  },

  async listar_agenda(tx, c) {
    const desde = opcional(c.desde, 10), hasta = opcional(c.hasta, 10);
    if (!desde || !hasta) throw new Error("datos_invalidos");
    const eventos = await tx`
      select e.id, e.tipo, e.titulo, e.inicio, e.fin, e.lugar, e.hecho, x.id as expediente_id, x.numero
      from despacho.eventos e left join despacho.expedientes x on x.id = e.expediente_id
      where e.inicio >= ${desde}::date and e.inicio < ${hasta}::date + 1
      order by e.inicio`;
    const festivos = await tx`select fecha::text, descripcion from despacho.festivos where fecha between ${desde}::date and ${hasta}::date`;
    return { eventos, festivos };
  },

  async crear_evento(tx, c) {
    const [r] = await tx`insert into despacho.eventos (tipo, titulo, expediente_id, inicio, fin, lugar)
      values (${enLista(c.tipo, TIPOS_EVENTO.filter((t) => t !== "cita_cliente"))}::despacho.tipo_evento, ${texto(c.titulo, 300)},
              ${opcional(c.expediente_id, 40)}::uuid, ${texto(c.inicio, 40)}::timestamptz, ${opcional(c.fin, 40)}::timestamptz,
              ${opcional(c.lugar, 200)}) returning id`;
    return r;
  },

  async marcar_evento(tx, c) {
    await tx`update despacho.eventos set hecho = ${c.hecho !== false} where id = ${texto(c.id, 40)}::uuid`;
    return { ok: true };
  },

  async listar_finanzas(tx, c) {
    const mes = typeof c.mes === "string" && /^\d{4}-\d{2}$/.test(c.mes) ? c.mes : null;
    const movimientos = await tx`
      select m.id, m.tipo, m.concepto, m.base_eur, m.iva_pct, m.total_eur, m.estado, m.fecha, m.vence_en, m.factura_ref,
             e.id as expediente_id, e.numero, e.titulo as expediente
      from despacho.movimientos m left join despacho.expedientes e on e.id = m.expediente_id
      where ${mes}::text is null or to_char(m.fecha, 'YYYY-MM') = ${mes}
      order by m.fecha desc, m.creado_en desc`;
    const [tot] = await tx`
      select coalesce(sum(total_eur) filter (where estado = 'cobrado' and tipo in ('honorario','provision_fondos')), 0) as cobrado,
             coalesce(sum(total_eur) filter (where estado = 'pendiente' and tipo in ('honorario','provision_fondos')), 0) as pendiente,
             coalesce(sum(total_eur) filter (where tipo in ('gasto','suplido') and estado <> 'anulado'), 0) as gastos,
             coalesce(sum(total_eur - base_eur) filter (where estado = 'cobrado' and tipo in ('honorario','provision_fondos')), 0) as iva_repercutido
      from despacho.movimientos where ${mes}::text is null or to_char(fecha, 'YYYY-MM') = ${mes}`;
    return { movimientos, totales: tot };
  },

  async crear_movimiento(tx, c) {
    const tipo = enLista(c.tipo, TIPOS_MOV);
    const iva = c.iva_pct == null || c.iva_pct === "" ? (tipo === "suplido" ? 0 : 21) : numero(c.iva_pct);
    const [r] = await tx`insert into despacho.movimientos (expediente_id, tipo, concepto, base_eur, iva_pct, estado, fecha, vence_en, factura_ref)
      values (${opcional(c.expediente_id, 40)}::uuid, ${tipo}::despacho.tipo_movimiento, ${texto(c.concepto, 300)}, ${numero(c.base_eur)}, ${iva},
              ${enLista(c.estado ?? "pendiente", ESTADOS_MOV)}::despacho.estado_movimiento,
              coalesce(${opcional(c.fecha, 10)}::date, current_date), ${opcional(c.vence_en, 10)}::date, ${opcional(c.factura_ref, 60)})
      returning id, total_eur`;
    return r;
  },

  async marcar_movimiento(tx, c) {
    await tx`update despacho.movimientos set estado = ${enLista(c.estado, ESTADOS_MOV)}::despacho.estado_movimiento
             where id = ${texto(c.id, 40)}::uuid`;
    return { ok: true };
  },

  async listar_oportunidades(tx) {
    return await tx`
      select o.id, o.necesidad, o.evidencia, o.confianza, o.estado, o.creado_en, m.nombre as materia,
             coalesce(cl1.nombre, cl2.nombre) as cliente, e.numero, e.id as expediente_id
      from despacho.oportunidades o
      left join despacho.materias m on m.codigo = o.materia_codigo
      left join despacho.leads l on l.id = o.lead_id left join despacho.clientes cl1 on cl1.id = l.cliente_id
      left join despacho.expedientes e on e.id = o.expediente_id left join despacho.clientes cl2 on cl2.id = e.cliente_id
      where o.estado not in ('descartada')
      order by (o.estado = 'detectada') desc, o.creado_en desc`;
  },

  async decidir_oportunidad(tx, c) {
    await tx`update despacho.oportunidades set estado = ${enLista(c.estado, ESTADOS_OPORT)}::despacho.estado_oportunidad,
             decidido_por = auth.uid(), decidido_en = now() where id = ${texto(c.id, 40)}::uuid`;
    return { ok: true };
  },

  async enviar_mensaje(tx, c) {
    const [r] = await tx`insert into despacho.mensajes (expediente_id, autor, texto)
      values (${texto(c.expediente_id, 40)}::uuid, 'abogado', ${texto(c.texto, 5000)}) returning id`;
    return r;
  },

  async compartir_documento(tx, c) {
    await tx`update despacho.documentos set visible_cliente = ${c.visible === true} where id = ${texto(c.id, 40)}::uuid`;
    return { ok: true };
  },
};

export type { Sql };
