import { esIdentificadorValido } from "./nif.ts";

export interface Contraparte { nombre: string; nif?: string }
export interface SolicitudConsulta {
  tipo: "fisica" | "juridica";
  nombre: string;
  nif?: string;
  email: string;
  telefono?: string;
  es_autonomo?: boolean;
  materia: string;
  descripcion: string;
  fecha_limite?: string;   // YYYY-MM-DD
  cuantia_eur?: number;
  documentacion_disponible?: boolean;
  contrapartes?: Contraparte[];
  acepta_privacidad: boolean;
  acepta_condiciones: boolean;
  acepta_comunicaciones?: boolean;
  version_textos?: string;
  web?: string;            // honeypot: debe llegar vacío
}

export type Errores = Record<string, string>;

const hoyISO = () => new Date().toISOString().slice(0, 10);

export function validarSolicitud(e: Partial<SolicitudConsulta>): Errores {
  const err: Errores = {};
  const txt = (v: unknown) => (typeof v === "string" ? v.trim() : "");

  if (e.tipo !== "fisica" && e.tipo !== "juridica") err.tipo = "Indica si eres persona física o empresa.";
  const nombre = txt(e.nombre);
  if (nombre.length < 2 || nombre.length > 200) err.nombre = "Indica tu nombre o razón social.";
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(txt(e.email))) err.email = "El email no parece válido.";

  const nif = txt(e.nif);
  if (e.tipo === "juridica" && !nif) err.nif = "El CIF es obligatorio para empresas.";
  else if (nif && (e.tipo === "fisica" || e.tipo === "juridica") && !esIdentificadorValido(nif, e.tipo)) {
    err.nif = e.tipo === "juridica" ? "El CIF no es válido." : "El DNI/NIE no es válido.";
  }

  const tel = txt(e.telefono);
  if (tel && !/^\+?[\d\s-]{9,15}$/.test(tel)) err.telefono = "El teléfono no parece válido.";

  if (!txt(e.materia)) err.materia = "Elige el tipo de asunto.";
  const desc = txt(e.descripcion);
  if (desc.length < 20) err.descripcion = "Cuéntanos el asunto con algo más de detalle (mínimo 20 caracteres).";
  if (desc.length > 4000) err.descripcion = "La descripción es demasiado larga (máximo 4000 caracteres).";

  if (e.fecha_limite) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(e.fecha_limite) || isNaN(Date.parse(e.fecha_limite))) err.fecha_limite = "Fecha no válida.";
    else if (e.fecha_limite < hoyISO()) err.fecha_limite = "La fecha límite ya ha pasado. Indícalo en la descripción.";
  }
  if (e.cuantia_eur != null && (typeof e.cuantia_eur !== "number" || !isFinite(e.cuantia_eur) || e.cuantia_eur < 0)) {
    err.cuantia_eur = "Cuantía no válida.";
  }

  const cps = e.contrapartes ?? [];
  if (!Array.isArray(cps) || cps.length > 5) err.contrapartes = "Máximo 5 partes contrarias.";
  else cps.forEach((c, i) => {
    if (txt(c?.nombre).length > 0 && txt(c?.nombre).length < 2) err[`contrapartes.${i}`] = "Nombre demasiado corto.";
  });

  if (e.acepta_privacidad !== true) err.acepta_privacidad = "Debes aceptar la política de privacidad.";
  if (e.acepta_condiciones !== true) err.acepta_condiciones = "Debes aceptar las condiciones de la consulta.";
  return err;
}

/** Traduce los códigos de error de la base de datos a mensajes para el público. */
export const MENSAJES_BD: Record<string, { campo?: string; mensaje: string; status: number }> = {
  nombre_invalido: { campo: "nombre", mensaje: "Indica tu nombre o razón social.", status: 422 },
  email_invalido: { campo: "email", mensaje: "El email no parece válido.", status: 422 },
  nif_obligatorio_juridica: { campo: "nif", mensaje: "El CIF es obligatorio para empresas.", status: 422 },
  falta_privacidad: { campo: "acepta_privacidad", mensaje: "Debes aceptar la política de privacidad.", status: 422 },
  faltan_condiciones: { campo: "acepta_condiciones", mensaje: "Debes aceptar las condiciones.", status: 422 },
  descripcion_invalida: { campo: "descripcion", mensaje: "Revisa la descripción del asunto.", status: 422 },
  fecha_limite_pasada: { campo: "fecha_limite", mensaje: "La fecha límite ya ha pasado.", status: 422 },
  cuantia_invalida: { campo: "cuantia_eur", mensaje: "Cuantía no válida.", status: 422 },
  demasiadas_contrapartes: { campo: "contrapartes", mensaje: "Máximo 5 partes contrarias.", status: 422 },
  materia_invalida: { campo: "materia", mensaje: "Elige un tipo de asunto de la lista.", status: 422 },
  limite_solicitudes: { mensaje: "Has enviado varias solicitudes hoy. Te responderemos en breve; no es necesario repetirla.", status: 429 },
};
