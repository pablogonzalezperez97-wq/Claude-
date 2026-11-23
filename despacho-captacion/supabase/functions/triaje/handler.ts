import type { Sql } from "../_shared/db.ts";
import { ipCliente, json } from "../_shared/http.ts";
import { MENSAJES_BD, type SolicitudConsulta, validarSolicitud } from "../_shared/validacion.ts";

const RESPUESTAS = {
  reservar: {
    titulo: "Tu consulta encaja",
    mensaje: "Puedes reservar ya tu consulta inicial de 30 minutos por videollamada (50 €).",
  },
  en_revision: {
    titulo: "Hemos recibido tu consulta",
    mensaje: "El abogado la revisará personalmente y te escribirá en un plazo máximo de 2 días laborables.",
  },
  derivar: {
    titulo: "Hemos recibido tu consulta",
    mensaje: "Por la naturaleza del asunto, el abogado te pondrá en contacto con un compañero especializado en un plazo máximo de 2 días laborables.",
  },
  no_encaja: {
    titulo: "Gracias por tu consulta",
    mensaje: "Con la información aportada no podemos ofrecerte cita. Si quieres, amplía los detalles y vuelve a enviarla.",
  },
} as const;

const EMERGENCIA =
  "Si hay una persona detenida, pide en comisaría el abogado del turno de oficio de guardia. " +
  "Ante una situación de violencia de género llama al 016 (gratuito, no deja rastro en la factura) o al 112 si hay peligro inmediato.";

export function crearHandlerTriaje(sql: () => Sql) {
  return async function handler(req: Request): Promise<Response> {
    if (req.method === "OPTIONS") return json(req, null, 204);

    if (req.method === "GET") {
      const materias = await sql()`
        select codigo, nombre, area, nivel from despacho.materias where activa
        order by case nivel when 'nucleo' then 1 when 'complementaria' then 2 else 3 end, area, nombre`;
      return json(req, { materias });
    }

    if (req.method !== "POST") return json(req, { error: "metodo_no_permitido" }, 405);

    let entrada: Partial<SolicitudConsulta>;
    try { entrada = await req.json(); } catch { return json(req, { error: "json_invalido" }, 400); }

    // Honeypot antispam: se responde como si todo fuese bien, sin guardar nada.
    if (entrada.web) return json(req, { resultado: "en_revision", ...RESPUESTAS.en_revision });

    const errores = validarSolicitud(entrada);
    if (Object.keys(errores).length) return json(req, { error: "validacion", errores }, 422);

    const { web: _web, ...datos } = entrada;
    try {
      const [fila] = await sql()`
        select despacho.registrar_lead(${sql().json(datos as never)}, ${ipCliente(req)}::inet,
                                       ${(req.headers.get("user-agent") ?? "").slice(0, 300)}) as r`;
      const r = fila.r as { lead_id: string; resultado: keyof typeof RESPUESTAS; motivo_derivacion?: string };
      return json(req, {
        referencia: r.lead_id.slice(0, 8).toUpperCase(),
        resultado: r.resultado,
        ...RESPUESTAS[r.resultado],
        motivo: r.motivo_derivacion ?? undefined,
        // Recursos de emergencia: nunca se omiten en asuntos urgentes.
        emergencia: r.resultado === "derivar" ? EMERGENCIA : undefined,
      });
    } catch (e) {
      const codigo = (e as { message?: string }).message ?? "";
      const m = MENSAJES_BD[codigo];
      if (m) return json(req, { error: codigo, errores: m.campo ? { [m.campo]: m.mensaje } : undefined, mensaje: m.mensaje }, m.status);
      console.error("triaje_error", codigo);
      return json(req, { error: "error_interno", mensaje: "No hemos podido registrar tu consulta. Inténtalo de nuevo en unos minutos." }, 500);
    }
  };
}
