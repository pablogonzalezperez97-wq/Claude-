import { assert, assertEquals } from "jsr:@std/assert@1.0.8";
import { esCifValido, esDniValido, esNieValido } from "../_shared/nif.ts";
import { validarSolicitud } from "../_shared/validacion.ts";

Deno.test("DNI", () => {
  assert(esDniValido("12345678Z"));
  assert(esDniValido("12.345.678-z"));
  assert(!esDniValido("12345678A"));
});

Deno.test("NIE", () => {
  assert(esNieValido("X1234567L"));
  assert(!esNieValido("X1234567A"));
});

Deno.test("CIF", () => {
  // B1234567 -> control 4
  assert(esCifValido("B12345674"));
  assert(!esCifValido("B12345675"));
  // Q (organismo) usa letra: Q2826000H
  assert(esCifValido("Q2826000H"));
  assert(!esCifValido("Q28260008"));
});

const base = {
  tipo: "juridica" as const, nombre: "Beta SL", nif: "B12345674", email: "a@b.es", materia: "mer_contratos",
  descripcion: "Revisión de un contrato de distribución exclusiva.", acepta_privacidad: true, acepta_condiciones: true,
};

Deno.test("solicitud válida", () => assertEquals(validarSolicitud(base), {}));
Deno.test("CIF incorrecto", () => assert(validarSolicitud({ ...base, nif: "B12345675" }).nif));
Deno.test("empresa sin CIF", () => assert(validarSolicitud({ ...base, nif: "" }).nif));
Deno.test("persona física sin DNI es válida", () => assertEquals(validarSolicitud({ ...base, tipo: "fisica", nif: "" }), {}));
Deno.test("sin consentimientos", () => {
  const e = validarSolicitud({ ...base, acepta_privacidad: false, acepta_condiciones: false });
  assert(e.acepta_privacidad && e.acepta_condiciones);
});
Deno.test("fecha pasada", () => assert(validarSolicitud({ ...base, fecha_limite: "2020-01-01" }).fecha_limite));
Deno.test("descripción corta", () => assert(validarSolicitud({ ...base, descripcion: "hola" }).descripcion));
