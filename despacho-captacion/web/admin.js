// Panel de gestión del despacho (vista del abogado).
// Todo dato que viene del servidor se pinta con textContent (nunca innerHTML) para evitar inyecciones.
(() => {
  const C = window.DESPACHO_CONFIG;
  const sb = supabase.createClient(C.SUPABASE_URL, C.SUPABASE_ANON_KEY);
  const API = `${C.SUPABASE_URL}/functions/v1/panel`;
  const $ = (s) => document.querySelector(s);
  const vista = $("#vista");

  // ---------- utilidades ----------
  const el = (tag, props = {}, ...hijos) => {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (k === "dataset") Object.assign(e.dataset, v);
      else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
      else if (k.includes("-")) e.setAttribute(k, v);
      else if (v !== undefined && v !== null) e[k] = v;
    }
    e.append(...hijos.flat().filter((h) => h !== null && h !== undefined && h !== false));
    return e;
  };
  const eur = (n) => Number(n ?? 0).toLocaleString("es-ES", { style: "currency", currency: "EUR" });
  const fecha = (s) => s ? new Date(s.length === 10 ? s + "T12:00:00" : s).toLocaleDateString("es-ES", { day: "2-digit", month: "short", year: "numeric" }) : "";
  const hora = (s) => s ? new Date(s).toLocaleTimeString("es-ES", { hour: "2-digit", minute: "2-digit" }) : "";
  const hoyISO = () => new Date().toISOString().slice(0, 10);
  const ETQ = {
    abierto: "Abierto", en_tramite: "En trámite", pendiente_revision: "Pendiente de revisión", urgente: "Urgente", suspendido: "Suspendido", cerrado: "Cerrado",
    vencimiento: "Vencimiento", audiencia: "Audiencia", reunion: "Reunión", cita_cliente: "Cita cliente", recordatorio: "Recordatorio",
    honorario: "Honorario", provision_fondos: "Provisión de fondos", suplido: "Suplido", gasto: "Gasto",
    pendiente: "Pendiente", cobrado: "Cobrado", pagado: "Pagado", anulado: "Anulado",
    detectada: "Por validar", validada: "Validada", ofrecida: "Ofrecida", aceptada: "Aceptada", descartada: "Descartada",
  };
  const estado = (v) => el("span", { className: `estado ${v}`, textContent: ETQ[v] ?? v });
  const MENSAJES = {
    conflictos_sin_resolver: "Resuelve primero los posibles conflictos de intereses.",
    no_autorizado: "Tu usuario no figura como abogado del despacho.",
    lead_no_revisable: "Esta solicitud ya no está pendiente.",
    datos_invalidos: "Revisa los datos introducidos.",
    no_encontrado: "No se ha encontrado el registro.",
  };
  const avisoError = (e) => alert(MENSAJES[e.message] || `No se pudo completar: ${e.message}`);

  async function api(accion, datos = {}) {
    const { data: { session } } = await sb.auth.getSession();
    const r = await fetch(API, {
      method: accion === null ? "GET" : "POST",
      headers: { apikey: C.SUPABASE_ANON_KEY, Authorization: `Bearer ${session?.access_token}`, "Content-Type": "application/json" },
      body: accion === null ? undefined : JSON.stringify({ accion, ...datos }),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(j.error || `HTTP ${r.status}`);
    return j;
  }

  function cabecera(titulo, ...acciones) {
    return el("div", { className: "cabecera" }, el("h1", { textContent: titulo }), el("div", { className: "acciones", style: "margin:0" }, ...acciones));
  }
  const boton = (texto, clase, fn) => el("button", { type: "button", className: clase, textContent: texto, onclick: fn });
  const cargando = () => vista.replaceChildren(el("p", { className: "meta", textContent: "Cargando…" }));
  const kpi = (etq, valor, destacado) => el("div", { className: `kpi${destacado ? " destacado" : ""}` }, el("div", { className: "etq", textContent: etq }), el("div", { className: "valor", textContent: valor }));

  function tabla(columnas, filas, alClic) {
    if (!filas.length) return el("div", { className: "tabla-envoltorio" }, el("div", { className: "vacio", textContent: "Sin registros." }));
    return el("div", { className: "tabla-envoltorio" }, el("table", { className: "tabla" },
      el("thead", {}, el("tr", {}, columnas.map((c) => el("th", { textContent: c.t, className: c.num ? "num" : "" })))),
      el("tbody", {}, filas.map((f) => el("tr", { className: alClic ? "clic" : "", onclick: alClic ? () => alClic(f) : undefined },
        columnas.map((c) => { const v = c.v(f); return el("td", { className: c.num ? "num" : "" }, v instanceof Node ? v : String(v ?? "")); }))))));
  }

  // Formulario modal genérico. campos: [{n, t, tipo, opciones, req, valor}]
  function formulario(titulo, campos, alEnviar) {
    const dlg = $("#dialogo");
    const form = el("form", { method: "dialog" },
      el("h2", { textContent: titulo }),
      campos.map((c) => {
        const id = `f-${c.n}`;
        let input;
        if (c.tipo === "select") input = el("select", { id, name: c.n }, c.opciones.map(([v, t]) => el("option", { value: v, textContent: t, selected: v === c.valor })));
        else if (c.tipo === "textarea") input = el("textarea", { id, name: c.n, value: c.valor ?? "" });
        else if (c.tipo === "checkbox") return el("label", { className: "check" }, el("input", { type: "checkbox", name: c.n, checked: !!c.valor }), c.t);
        else input = el("input", { id, name: c.n, type: c.tipo || "text", value: c.valor ?? "", required: !!c.req, step: c.tipo === "number" ? "0.01" : undefined });
        return [el("label", { htmlFor: id, textContent: c.t }), input];
      }),
      el("div", { className: "acciones" },
        el("button", { type: "submit", className: "primario", textContent: "Guardar" }),
        el("button", { type: "button", className: "secundario", textContent: "Cancelar", onclick: () => dlg.close() })));
    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const datos = {};
      for (const c of campos) {
        const i = form.elements[c.n];
        datos[c.n] = c.tipo === "checkbox" ? i.checked : (i.value === "" ? null : (c.tipo === "number" ? Number(i.value) : i.value));
      }
      try { await alEnviar(datos); dlg.close(); } catch (e) { avisoError(e); }
    });
    dlg.replaceChildren(form);
    dlg.showModal();
  }

  // ---------- vistas ----------
  const VISTAS = {};

  VISTAS.resumen = async () => {
    const d = await api("dashboard");
    actualizarContadores(d);
    const estados = Object.entries(d.expedientes_por_estado || {});
    vista.replaceChildren(
      cabecera("Resumen", boton("+ Expediente", "primario", () => location.hash = "#solicitudes"), boton("+ Tarea", "secundario", () => nuevaTarea())),
      el("div", { className: "kpis" },
        kpi("Vencimientos · 7 días", d.vencimientos_7d, true), kpi("Audiencias · 7 días", d.audiencias_7d),
        kpi("Citas · 7 días", d.citas_7d), kpi("Expedientes activos", d.expedientes_activos),
        kpi("Pendiente de cobro", eur(d.pendiente_cobro_eur)), kpi("Tareas atrasadas", d.tareas_atrasadas)),
      el("div", { className: "rejilla-2" },
        el("section", { className: "tarjeta" }, el("h2", { textContent: "Próximos 7 días" }),
          d.proximos.length ? el("ul", { className: "lista-proximos" }, d.proximos.map((e) => el("li", {}, el("span", { className: `ev ${e.tipo}`, textContent: ETQ[e.tipo] }),
            el("span", { textContent: `${fecha(e.inicio)} ${hora(e.inicio)} · ${e.titulo}` }), e.numero ? el("span", { className: "meta", textContent: e.numero }) : null)))
            : el("p", { className: "meta", textContent: "Nada programado." })),
        el("section", { className: "tarjeta" }, el("h2", { textContent: "Este mes" }),
          el("div", { className: "ficha" },
            dato("Ingresos cobrados", eur(d.ingresos_mes_eur)), dato("Gastos y suplidos", eur(d.gastos_mes_eur)),
            dato("Balance", eur(Number(d.ingresos_mes_eur) - Number(d.gastos_mes_eur))),
            dato("Solicitudes por revisar", d.solicitudes_pendientes), dato("Oportunidades por validar", d.oportunidades_por_validar)),
          el("h2", { textContent: "Expedientes por estado", style: "margin-top:16px" }),
          estados.length ? el("div", { className: "filtros" }, estados.map(([k, n]) => el("span", {}, estado(k), ` ${n}`))) : el("p", { className: "meta", textContent: "Sin expedientes activos." }))));
  };
  const dato = (etq, valor) => el("div", { className: "dato" }, el("div", { className: "etq", textContent: etq }), el("div", { textContent: String(valor ?? "—") }));

  function actualizarContadores(d) {
    for (const [id, n] of [["c-solicitudes", d.solicitudes_pendientes], ["c-tareas", d.tareas_atrasadas], ["c-oportunidades", d.oportunidades_por_validar]]) {
      const c = document.getElementById(id); c.textContent = n; c.hidden = !Number(n);
    }
  }

  // --- Solicitudes (embudo) y derivaciones ---
  VISTAS.solicitudes = async () => {
    const { pendientes, derivaciones } = await api(null);
    vista.replaceChildren(cabecera("Solicitudes"),
      el("p", { className: "meta", textContent: "Consultas que han pasado el triaje. Acepta para que reserven, o abre directamente el expediente." }),
      ...(pendientes.length ? pendientes.map(tarjetaSolicitud) : [el("div", { className: "aviso ok", textContent: "No hay solicitudes pendientes." })]),
      el("h2", { textContent: "Derivaciones por reenviar", style: "margin-top:28px" }),
      ...(derivaciones.length ? derivaciones.map(grupoDerivacion) : [el("div", { className: "aviso ok", textContent: "No hay derivaciones por reenviar." })]));
  };

  function tarjetaSolicitud(l) {
    const t = el("article", { className: "tarjeta" },
      el("div", {},
        l.alerta_plazo ? el("span", { className: "chip alerta", textContent: `Plazo: ${l.dias_habiles} días hábiles` }) : null,
        l.conflictos.some((k) => k.estado === "pendiente") ? el("span", { className: "chip mal", textContent: "Posible conflicto" }) : null,
        el("span", { className: "chip", textContent: l.estado === "apto" ? "Apto (agenda directa)" : "Revisión" }),
        el("span", { className: "chip", textContent: `${l.puntuacion ?? 0} pts` })),
      el("h2", { textContent: `${l.cliente.nombre} · ${l.materia?.nombre ?? "Sin clasificar"}` }),
      el("p", { className: "meta", textContent: `Responder antes del ${fecha(l.responder_antes)}` }),
      el("p", { className: "meta", textContent: [l.cliente.tipo === "juridica" ? "Empresa" : "Particular", l.cliente.nif, l.contacto.email, l.contacto.telefono,
        l.cuantia_eur != null ? eur(l.cuantia_eur) : null, l.fecha_limite ? `Vence ${fecha(l.fecha_limite)}` : null].filter(Boolean).join(" · ") }),
      el("div", { className: "relato", textContent: l.descripcion ?? "" }),
      l.contrapartes.length ? el("p", { className: "meta", textContent: "Parte contraria: " + l.contrapartes.map((c) => c.nif ? `${c.nombre} (${c.nif})` : c.nombre).join(", ") }) : null);
    for (const k of l.conflictos) {
      const caja = el("div", { className: `aviso ${k.estado === "pendiente" ? "mal" : "ok"}` }, el("strong", { textContent: `Conflicto (${k.criterio}, similitud ${k.similitud}): ` }), k.detalle,
        k.estado !== "pendiente" ? ` — ${k.estado}` : "");
      if (k.estado === "pendiente") caja.append(el("div", { className: "acciones" },
        boton("No es conflicto", "secundario", () => accionYRecargar("decidir_conflicto", { conflicto_id: k.id, estado: "descartado" })),
        boton("Confirmar conflicto", "peligro", () => confirm("Se descartará el asunto. ¿Confirmas el conflicto?") && accionYRecargar("decidir_conflicto", { conflicto_id: k.id, estado: "confirmado" }))));
      t.append(caja);
    }
    t.append(el("div", { className: "acciones" },
      boton("Abrir expediente", "primario", () => formulario("Abrir expediente", [
        { n: "titulo", t: "Título del expediente", req: true, valor: `${l.cliente.nombre} · ${l.materia?.nombre ?? "asunto"}` },
        { n: "honorarios", t: "Honorarios pactados (€, IVA incl.)", tipo: "number" }],
        async (d) => { const r = await api("abrir_expediente", { lead_id: l.id, ...d }); location.hash = `#expediente/${r.id}`; })),
      boton("Aceptar (que reserve)", "secundario", () => accionYRecargar("decidir_lead", { lead_id: l.id, decision: "aceptar" })),
      boton("Derivar", "secundario", () => accionYRecargar("decidir_lead", { lead_id: l.id, decision: "derivar" })),
      boton("Rechazar", "peligro", () => confirm("¿Rechazar esta solicitud?") && accionYRecargar("decidir_lead", { lead_id: l.id, decision: "rechazar" }))));
    return t;
  }

  function grupoDerivacion(g) {
    const sel = new Set(g.casos.map((c) => c.id));
    const resumen = () => g.casos.filter((c) => sel.has(c.id)).map((c, i) => [`${i + 1}. ${c.materia ?? "Asunto"} — ${c.cliente}`,
      `   Contacto: ${[c.email, c.telefono].filter(Boolean).join(" · ")}`, c.fecha_limite ? `   Plazo: ${fecha(c.fecha_limite)}` : null,
      c.contrapartes.length ? `   Parte contraria: ${c.contrapartes.join(", ")}` : null, `   Relato: ${c.descripcion ?? ""}`].filter(Boolean).join("\n")).join("\n\n");
    return el("article", { className: "tarjeta" },
      el("h2", { textContent: `${g.area[0].toUpperCase()}${g.area.slice(1)} · ${g.casos.length} caso(s)` }),
      g.casos.map((c) => el("label", { className: "check" },
        el("input", { type: "checkbox", checked: true, onchange: (e) => e.target.checked ? sel.add(c.id) : sel.delete(c.id) }),
        el("span", {}, el("strong", { textContent: `${c.materia ?? "Asunto"} — ${c.cliente}` }),
          el("span", { className: "meta", textContent: ` · ${[c.email, c.telefono].filter(Boolean).join(" · ")}` }),
          el("div", { className: "relato", textContent: c.descripcion ?? "" })))),
      el("div", { className: "acciones" },
        boton("Copiar resumen", "secundario", async () => { const t = resumen(); try { await navigator.clipboard.writeText(t); alert("Resumen copiado."); } catch { prompt("Copia el resumen:", t); } }),
        boton("Marcar como reenviado", "primario", async () => {
          if (!sel.size) return alert("Selecciona al menos un caso.");
          const destinatario = prompt("¿A quién lo has reenviado?"); if (!destinatario) return;
          accionYRecargar("marcar_reenviado", { lead_ids: [...sel], destinatario });
        })));
  }

  async function accionYRecargar(accion, datos) {
    try { await api(accion, datos); await router(); } catch (e) { avisoError(e); }
  }

  // --- Expedientes ---
  VISTAS.expedientes = async (filtro = "") => {
    const lista = await api("listar_expedientes", { estado: filtro || undefined });
    const sel = el("select", { onchange: (e) => VISTAS.expedientes(e.target.value) },
      el("option", { value: "", textContent: "Todos los estados" }),
      Object.keys(ETQ).slice(0, 6).map((k) => el("option", { value: k, textContent: ETQ[k], selected: k === filtro })));
    vista.replaceChildren(cabecera("Expedientes", sel),
      tabla([
        { t: "Nº", v: (e) => e.numero }, { t: "Expediente", v: (e) => el("div", {}, el("strong", { textContent: e.titulo }), el("div", { className: "meta", textContent: e.cliente })) },
        { t: "Materia", v: (e) => e.materia ?? "" }, { t: "Estado", v: (e) => estado(e.estado) },
        { t: "Próximo evento", v: (e) => fecha(e.proximo_evento) }, { t: "Pendiente cobro", num: true, v: (e) => Number(e.pendiente_cobro) ? eur(e.pendiente_cobro) : "—" },
      ], lista, (e) => location.hash = `#expediente/${e.id}`));
  };

  VISTAS.expediente = async (id, pestana = "resumen") => {
    const x = await api("detalle_expediente", { id });
    const pestanas = [["resumen", "Resumen"], ["tareas", `Tareas (${x.tareas.filter((t) => !t.hecha).length})`], ["agenda", `Agenda (${x.eventos.length})`],
      ["finanzas", "Finanzas"], ["documentos", `Documentos (${x.documentos.length})`], ["mensajes", `Mensajes (${x.mensajes.length})`],
      ["oportunidades", `Oportunidades (${x.oportunidades.length})`]];
    const contenido = el("div");
    const barra = el("div", { className: "pestanas" }, pestanas.map(([k, t]) => el("button", { type: "button", className: k === pestana ? "activa" : "", textContent: t,
      onclick: () => VISTAS.expediente(id, k) })));
    vista.replaceChildren(
      el("p", {}, el("a", { href: "#expedientes", textContent: "← Expedientes" })),
      cabecera(`${x.numero} · ${x.titulo}`, estado(x.estado),
        boton("Editar", "secundario", () => editarExpediente(x))),
      el("p", { className: "meta", textContent: [x.cliente.nombre, x.cliente.nif, x.cliente.email, x.cliente.telefono, x.cliente.portal ? "Con acceso al portal" : "Sin acceso al portal"].filter(Boolean).join(" · ") }),
      barra, contenido);
    const recargar = () => VISTAS.expediente(id, pestana);
    const P = {
      resumen: () => [el("section", { className: "tarjeta" }, el("div", { className: "ficha" },
          dato("Materia", x.materia), dato("Contraparte", x.contraparte), dato("Órgano", x.organo), dato("Procedimiento", x.procedimiento),
          dato("Honorarios pactados", x.honorarios_pactados != null ? eur(x.honorarios_pactados) : "—"), dato("Abierto", fecha(x.abierto_en)),
          dato("Hoja de encargo", x.hoja_encargo_firmada ? "Firmada" : "Pendiente"),
          dato("Diligencia PBC", x.pbc_diligencia_ok === null ? "No aplica / sin evaluar" : x.pbc_diligencia_ok ? "Completada" : "Pendiente"))),
        el("section", { className: "tarjeta" }, el("h2", { textContent: "Notas internas (nunca visibles para el cliente)" }),
          el("div", { className: "relato", textContent: x.notas_internas || "Sin notas." }))],
      tareas: () => [el("div", { className: "acciones" }, boton("+ Tarea", "primario", () => nuevaTarea(id, recargar))), listaTareas(x.tareas, recargar)],
      agenda: () => [el("div", { className: "acciones" }, boton("+ Evento", "primario", () => nuevoEvento(id, recargar))),
        tabla([{ t: "Fecha", v: (e) => `${fecha(e.inicio)} ${hora(e.inicio)}` }, { t: "Tipo", v: (e) => el("span", { className: `ev ${e.tipo}`, textContent: ETQ[e.tipo] }) },
          { t: "Título", v: (e) => e.titulo }, { t: "", v: (e) => e.hecho ? estado("hecha") : boton("Hecho", "secundario", (ev) => { ev.stopPropagation(); accionYRecargar("marcar_evento", { id: e.id }); }) }], x.eventos)],
      finanzas: () => {
        const cobrado = x.movimientos.filter((m) => m.estado === "cobrado").reduce((s, m) => s + Number(m.total_eur), 0);
        const pend = x.movimientos.filter((m) => m.estado === "pendiente" && ["honorario", "provision_fondos"].includes(m.tipo)).reduce((s, m) => s + Number(m.total_eur), 0);
        return [el("div", { className: "kpis" }, kpi("Honorarios pactados", x.honorarios_pactados != null ? eur(x.honorarios_pactados) : "—"), kpi("Cobrado", eur(cobrado)), kpi("Pendiente", eur(pend), pend > 0)),
          el("div", { className: "acciones" }, boton("+ Movimiento", "primario", () => nuevoMovimiento(id, recargar))), tablaMovimientos(x.movimientos)];
      },
      documentos: () => [el("p", { className: "meta", textContent: "La subida de archivos llegará con el almacenamiento seguro (fase P2). Por defecto ningún documento se comparte con el cliente." }),
        tabla([{ t: "Documento", v: (d) => d.nombre_original }, { t: "Categoría", v: (d) => d.categoria ?? "" }, { t: "Subido", v: (d) => `${fecha(d.subido_en)} · ${d.subido_por}` },
          { t: "Revisado", v: (d) => d.revisado ? "Sí" : "No" },
          { t: "Compartido", v: (d) => boton(d.visible_cliente ? "Compartido ✓" : "Compartir", "secundario", () => accionYRecargar("compartir_documento", { id: d.id, visible: !d.visible_cliente })) }], x.documentos)],
      mensajes: () => {
        const caja = el("textarea", { placeholder: "Escribe al cliente…", maxLength: 5000 });
        return [el("section", { className: "tarjeta" },
          el("div", { className: "chat" }, x.mensajes.length ? x.mensajes.map((m) => el("div", { className: `burbuja ${m.autor}` },
            el("div", { className: "meta", textContent: `${m.autor === "abogado" ? "Tú" : x.cliente.nombre} · ${fecha(m.creado_en)} ${hora(m.creado_en)}` }), m.texto)) : el("p", { className: "vacio", textContent: "Sin mensajes." })),
          caja, el("div", { className: "acciones" }, boton("Enviar", "primario", async () => {
            if (!caja.value.trim()) return; await accionYRecargar("enviar_mensaje", { expediente_id: id, texto: caja.value }); })))];
      },
      oportunidades: () => [tablaOportunidades(x.oportunidades, recargar)],
    };
    contenido.replaceChildren(...P[pestana]());
  };

  function editarExpediente(x) {
    formulario("Editar expediente", [
      { n: "titulo", t: "Título", valor: x.titulo, req: true },
      { n: "estado", t: "Estado", tipo: "select", valor: x.estado, opciones: Object.keys(ETQ).slice(0, 6).map((k) => [k, ETQ[k]]) },
      { n: "contraparte", t: "Contraparte", valor: x.contraparte }, { n: "organo", t: "Órgano (juzgado, AEAT, registro…)", valor: x.organo },
      { n: "procedimiento", t: "Procedimiento / referencia", valor: x.procedimiento },
      { n: "honorarios_pactados", t: "Honorarios pactados (€, IVA incl.)", tipo: "number", valor: x.honorarios_pactados },
      { n: "hoja_encargo_firmada", t: "Hoja de encargo firmada", tipo: "checkbox", valor: x.hoja_encargo_firmada },
      { n: "pbc_diligencia_ok", t: "Diligencia debida PBC completada", tipo: "checkbox", valor: x.pbc_diligencia_ok },
      { n: "notas_internas", t: "Notas internas", tipo: "textarea", valor: x.notas_internas },
    ], async (d) => { await api("actualizar_expediente", { id: x.id, ...d }); VISTAS.expediente(x.id); });
  }

  // --- Tareas ---
  function listaTareas(tareas, recargar) {
    return tabla([
      { t: "", v: (t) => el("input", { type: "checkbox", checked: t.hecha, "aria-label": "Hecha", onclick: (ev) => ev.stopPropagation(),
        onchange: async (ev) => { try { await api("completar_tarea", { id: t.id, hecha: ev.target.checked }); recargar(); } catch (e) { avisoError(e); } } }) },
      { t: "Tarea", v: (t) => t.titulo }, { t: "Expediente", v: (t) => t.numero ? `${t.numero} · ${t.expediente}` : "" },
      { t: "Vence", v: (t) => t.vence_en ? el("span", {}, fecha(t.vence_en), !t.hecha && t.vence_en < hoyISO() ? el("span", { className: "estado atrasada", style: "margin-left:6px", textContent: "Atrasada" }) : "") : "" },
    ], tareas, (t) => t.expediente_id && (location.hash = `#expediente/${t.expediente_id}`));
  }
  VISTAS.tareas = async () => {
    const tareas = await api("listar_tareas");
    vista.replaceChildren(cabecera("Tareas", boton("+ Tarea", "primario", () => nuevaTarea(null, VISTAS.tareas))), listaTareas(tareas, VISTAS.tareas));
  };
  function nuevaTarea(expediente_id = null, despues = router) {
    formulario("Nueva tarea", [{ n: "titulo", t: "Tarea", req: true }, { n: "vence_en", t: "Vence", tipo: "date" }],
      async (d) => { await api("crear_tarea", { ...d, expediente_id }); despues(); });
  }

  // --- Agenda ---
  let mesAgenda = new Date(); mesAgenda.setDate(1);
  VISTAS.agenda = async () => {
    const y = mesAgenda.getFullYear(), m = mesAgenda.getMonth();
    const primero = new Date(y, m, 1), ultimo = new Date(y, m + 1, 0);
    const inicio = new Date(primero); inicio.setDate(1 - ((primero.getDay() + 6) % 7));
    const fin = new Date(ultimo); fin.setDate(ultimo.getDate() + (7 - ((ultimo.getDay() + 6) % 7 + 1)));
    const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    const { eventos, festivos } = await api("listar_agenda", { desde: iso(inicio), hasta: iso(fin) });
    const fest = Object.fromEntries(festivos.map((f) => [f.fecha, f.descripcion]));
    const celdas = [];
    for (let d = new Date(inicio); d <= fin; d.setDate(d.getDate() + 1)) {
      const k = iso(d), evs = eventos.filter((e) => iso(new Date(e.inicio)) === k);
      celdas.push(el("div", { className: `dia${d.getMonth() !== m ? " fuera" : ""}${k === hoyISO() ? " hoy" : ""}${fest[k] ? " festivo" : ""}`, title: fest[k] ?? "" },
        el("div", { className: "n" }, el("span", { textContent: d.getDate() }), fest[k] ? el("span", { className: "meta", textContent: "Festivo" }) : null),
        evs.map((e) => el("a", { className: `ev ${e.tipo}${e.hecho ? " hecho" : ""}`, href: e.expediente_id ? `#expediente/${e.expediente_id}` : "#agenda",
          textContent: `${hora(e.inicio)} ${e.titulo}`, title: `${ETQ[e.tipo]} · ${e.titulo}` }))));
    }
    const titulo = primero.toLocaleDateString("es-ES", { month: "long", year: "numeric" });
    vista.replaceChildren(
      cabecera(titulo[0].toUpperCase() + titulo.slice(1),
        boton("←", "secundario", () => { mesAgenda.setMonth(m - 1); VISTAS.agenda(); }),
        boton("Hoy", "secundario", () => { mesAgenda = new Date(); mesAgenda.setDate(1); VISTAS.agenda(); }),
        boton("→", "secundario", () => { mesAgenda.setMonth(m + 1); VISTAS.agenda(); }),
        boton("+ Evento", "primario", () => nuevoEvento(null, VISTAS.agenda))),
      el("div", { className: "leyenda" }, ["vencimiento", "audiencia", "cita_cliente", "reunion", "recordatorio"].map((t) => el("span", { className: `ev ${t}`, textContent: ETQ[t] }))),
      el("div", { className: "calendario" }, ["Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"].map((d) => el("div", { className: "dia-sem", textContent: d })), celdas));
  };
  function nuevoEvento(expediente_id = null, despues = router) {
    formulario("Nuevo evento", [
      { n: "tipo", t: "Tipo", tipo: "select", valor: "vencimiento", opciones: ["vencimiento", "audiencia", "reunion", "recordatorio"].map((k) => [k, ETQ[k]]) },
      { n: "titulo", t: "Título", req: true }, { n: "inicio", t: "Fecha y hora", tipo: "datetime-local", req: true }, { n: "lugar", t: "Lugar" }],
      async (d) => { await api("crear_evento", { ...d, inicio: new Date(d.inicio).toISOString(), expediente_id }); despues(); });
  }

  // --- Finanzas ---
  function tablaMovimientos(movs) {
    return tabla([
      { t: "Fecha", v: (m) => fecha(m.fecha) }, { t: "Concepto", v: (m) => el("div", {}, el("strong", { textContent: m.concepto }), m.numero ? el("div", { className: "meta", textContent: `${m.numero} · ${m.expediente}` }) : null) },
      { t: "Tipo", v: (m) => ETQ[m.tipo] }, { t: "Base", num: true, v: (m) => eur(m.base_eur) }, { t: "IVA", num: true, v: (m) => `${Number(m.iva_pct)} %` },
      { t: "Total", num: true, v: (m) => eur(m.total_eur) }, { t: "Estado", v: (m) => estado(m.estado) },
      { t: "", v: (m) => m.estado === "pendiente" ? boton(["gasto", "suplido"].includes(m.tipo) ? "Pagado" : "Cobrado", "secundario", (ev) => { ev.stopPropagation();
        accionYRecargar("marcar_movimiento", { id: m.id, estado: ["gasto", "suplido"].includes(m.tipo) ? "pagado" : "cobrado" }); }) : "" },
    ], movs);
  }
  let mesFinanzas = hoyISO().slice(0, 7);
  VISTAS.finanzas = async () => {
    const { movimientos, totales } = await api("listar_finanzas", { mes: mesFinanzas || undefined });
    const selMes = el("input", { type: "month", value: mesFinanzas, onchange: (e) => { mesFinanzas = e.target.value; VISTAS.finanzas(); } });
    vista.replaceChildren(
      cabecera("Finanzas", selMes, boton("Todo", "secundario", () => { mesFinanzas = ""; VISTAS.finanzas(); }), boton("+ Movimiento", "primario", () => nuevoMovimiento(null, VISTAS.finanzas))),
      el("div", { className: "kpis" }, kpi("Cobrado", eur(totales.cobrado), true), kpi("Pendiente de cobro", eur(totales.pendiente)),
        kpi("Gastos y suplidos", eur(totales.gastos)), kpi("IVA repercutido (cobrado)", eur(totales.iva_repercutido))),
      tablaMovimientos(movimientos));
  };
  function nuevoMovimiento(expediente_id = null, despues = router) {
    formulario("Nuevo movimiento", [
      { n: "tipo", t: "Tipo", tipo: "select", valor: "honorario", opciones: ["honorario", "provision_fondos", "suplido", "gasto"].map((k) => [k, ETQ[k]]) },
      { n: "concepto", t: "Concepto", req: true }, { n: "base_eur", t: "Base imponible (€)", tipo: "number", req: true },
      { n: "iva_pct", t: "IVA % (vacío = 21 %; suplidos 0 %)", tipo: "number" },
      { n: "estado", t: "Estado", tipo: "select", valor: "pendiente", opciones: ["pendiente", "cobrado", "pagado"].map((k) => [k, ETQ[k]]) },
      { n: "fecha", t: "Fecha", tipo: "date", valor: hoyISO() }, { n: "vence_en", t: "Vencimiento", tipo: "date" }, { n: "factura_ref", t: "Nº de factura" }],
      async (d) => { await api("crear_movimiento", { ...d, expediente_id }); despues(); });
  }

  // --- Clientes ---
  VISTAS.clientes = async () => {
    const lista = await api("listar_clientes");
    vista.replaceChildren(cabecera("Clientes"),
      tabla([{ t: "Cliente", v: (c) => el("div", {}, el("strong", { textContent: c.nombre }), el("div", { className: "meta", textContent: c.nif ?? "" })) },
        { t: "Contacto", v: (c) => [c.email, c.telefono].filter(Boolean).join(" · ") }, { t: "Tipo", v: (c) => c.tipo === "juridica" ? "Empresa" : "Particular" },
        { t: "Expedientes activos", num: true, v: (c) => c.expedientes_activos }, { t: "Portal", v: (c) => c.portal ? "Sí" : "No" }], lista));
  };

  // --- Oportunidades (cross-selling validado) ---
  function tablaOportunidades(lista, recargar) {
    return tabla([
      { t: "Necesidad detectada", v: (o) => el("div", {}, el("strong", { textContent: o.necesidad }), el("div", { className: "meta", textContent: `Evidencia: ${o.evidencia}` })) },
      { t: "Materia", v: (o) => o.materia ?? "" }, { t: "Cliente", v: (o) => o.cliente ?? "" },
      { t: "Confianza", num: true, v: (o) => o.confianza != null ? `${Math.round(o.confianza * 100)} %` : "" }, { t: "Estado", v: (o) => estado(o.estado) },
      { t: "", v: (o) => el("div", { className: "filtros" },
        o.estado === "detectada" ? [boton("Validar", "primario", () => decidir(o.id, "validada")), boton("Descartar", "peligro", () => decidir(o.id, "descartada"))] : null,
        o.estado === "validada" ? boton("Ofrecida", "secundario", () => decidir(o.id, "ofrecida")) : null,
        o.estado === "ofrecida" ? boton("Aceptada", "secundario", () => decidir(o.id, "aceptada")) : null) },
    ], lista);
    async function decidir(id, estadoNuevo) { try { await api("decidir_oportunidad", { id, estado: estadoNuevo }); recargar(); } catch (e) { avisoError(e); } }
  }
  VISTAS.oportunidades = async () => {
    const lista = await api("listar_oportunidades");
    vista.replaceChildren(cabecera("Oportunidades"),
      el("p", { className: "meta", textContent: "Necesidades adicionales que el asistente ha detectado en la conversación con el cliente. Ninguna se ofrece sin tu validación." }),
      tablaOportunidades(lista, VISTAS.oportunidades));
  };

  // ---------- enrutado y sesión ----------
  async function router() {
    const [ruta, param] = (location.hash.slice(1) || "resumen").split("/");
    document.querySelectorAll(".lateral a[data-ruta]").forEach((a) => a.classList.toggle("activo", a.dataset.ruta === ruta || (ruta === "expediente" && a.dataset.ruta === "expedientes")));
    cargando();
    try { await (ruta === "expediente" ? VISTAS.expediente(param) : (VISTAS[ruta] ?? VISTAS.resumen)()); }
    catch (e) { vista.replaceChildren(el("div", { className: "aviso mal", textContent: MENSAJES[e.message] || `No se pudo cargar (${e.message}).` })); }
  }

  async function iniciar() {
    const { data: { session } } = await sb.auth.getSession();
    $("#login").hidden = !!session; $("#app").hidden = !session;
    if (!session) return;
    $("#usuario").textContent = session.user.email;
    if (C.NOMBRE_DESPACHO) $("#marca").textContent = C.NOMBRE_DESPACHO;
    router();
    api("dashboard").then(actualizarContadores).catch(() => {});
  }

  $("#form-login").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const { error } = await sb.auth.signInWithOtp({ email: $("#email-login").value.trim(), options: { emailRedirectTo: location.origin + location.pathname, shouldCreateUser: false } });
    $("#aviso-login").replaceChildren(el("div", { className: `aviso ${error ? "mal" : "ok"}`, textContent: error ? "No se pudo enviar el enlace." : "Revisa tu email y abre el enlace de acceso." }));
  });
  $("#salir").addEventListener("click", async (e) => { e.preventDefault(); await sb.auth.signOut(); iniciar(); });
  window.addEventListener("hashchange", router);
  sb.auth.onAuthStateChange((evento) => { if (evento === "SIGNED_IN" || evento === "SIGNED_OUT") iniciar(); });
  iniciar();
})();
