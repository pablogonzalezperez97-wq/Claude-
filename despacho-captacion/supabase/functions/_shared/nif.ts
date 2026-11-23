// Validación de identificadores fiscales españoles: DNI, NIE y CIF/NIF de entidades.
const LETRAS_DNI = "TRWAGMYFPDXBNJZSQVHLCKE";

export function normalizarNif(v: string): string {
  return (v ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");
}

export function esDniValido(v: string): boolean {
  const n = normalizarNif(v);
  if (!/^\d{8}[A-Z]$/.test(n)) return false;
  return LETRAS_DNI[parseInt(n.slice(0, 8), 10) % 23] === n[8];
}

export function esNieValido(v: string): boolean {
  const n = normalizarNif(v);
  if (!/^[XYZ]\d{7}[A-Z]$/.test(n)) return false;
  const num = "XYZ".indexOf(n[0]) + n.slice(1, 8);
  return LETRAS_DNI[parseInt(num, 10) % 23] === n[8];
}

export function esCifValido(v: string): boolean {
  const n = normalizarNif(v);
  if (!/^[ABCDEFGHJNPQRSUVW]\d{7}[0-9A-J]$/.test(n)) return false;
  const digitos = n.slice(1, 8);
  let pares = 0, impares = 0;
  for (let i = 0; i < 7; i++) {
    const d = parseInt(digitos[i], 10);
    if (i % 2 === 0) { const x = d * 2; impares += Math.floor(x / 10) + (x % 10); }
    else pares += d;
  }
  const control = (10 - ((pares + impares) % 10)) % 10;
  const letraControl = "JABCDEFGHI"[control];
  const c = n[8];
  // Según el tipo de entidad, el control es letra, número o cualquiera de los dos.
  if ("PQRSNW".includes(n[0])) return c === letraControl;
  if ("ABEH".includes(n[0])) return c === String(control);
  return c === String(control) || c === letraControl;
}

export function esIdentificadorValido(v: string, tipo: "fisica" | "juridica"): boolean {
  return tipo === "juridica" ? esCifValido(v) : esDniValido(v) || esNieValido(v);
}
