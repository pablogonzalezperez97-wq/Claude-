# Despacho de tarde · Sistema de captación y agenda

Sistema para un despacho de abogado generalista, con práctica centrada en derecho mercantil, a tiempo parcial. Durante el día capta, informa, filtra, cobra y agenda; por la tarde el abogado atiende con el expediente ya preparado.

## Documentación

1. [Benchmark de modelos análogos](docs/01-benchmark-modelos-analogos.md): qué hacen Doctoralia, Booksy, TaxDown, Clio Grow, los chatbots inmobiliarios y las plataformas de psicología online, y qué extrapolamos.
2. [Estructura de producción](docs/02-estructura-produccion.md): módulos, flujo, modelo de datos, scoring, salvaguardas de la IA, fases y criterios de aceptación.
3. [Requerimientos por tu parte](docs/03-requerimientos-cliente.md): checklist priorizado de decisiones, contenidos y cuentas.
4. [Plataforma completa](docs/04-plataforma-completa.md): panel del abogado, portal del cliente, asistente de voz con cross-selling y fases P1-P7.

## Estado

- [x] F0 · Benchmark y estructura de producción
- [x] F0 · Decisiones de negocio (bloque B cerrado)
- [x] F1 · Esquema de datos: migraciones en `supabase/migrations/`, probadas en PostgreSQL local
- [x] F2 (base) · Triaje, scoring, derivación y comprobación de conflictos en la base de datos
- [ ] F1 · Despliegue en el entorno de **pruebas** (proyecto de Frankfurt, esquema `despacho`, sin datos reales). Bloqueado: el proyecto está hibernado y no responde
- [ ] F7 · Proyecto exclusivo en plan Pro para producción (antes del lanzamiento)
- [x] F2 · Formulario de consulta (`web/consulta.html`) y bandeja de revisión (`web/panel.html`)
- [x] F2 · Edge Functions `triaje` (pública) y `panel` (abogado), con pruebas unitarias, de integración y en navegador
- [x] F2 · Derivaciones manuales agrupadas por área, plazo de respuesta de 2 días hábiles y recursos de emergencia
- [x] P1 (datos) · Expedientes, agenda, tareas, finanzas, documentos, portal del cliente y oportunidades IA, con pruebas de aislamiento
- [ ] P1 · Interfaz del panel del abogado
- [ ] F3/P4 · Reserva (Cal.com) y pago (Stripe)

## Estructura

```
config/negocio.yaml          Parámetros del despacho (fuente única de verdad)
supabase/migrations/         Esquema (aislado en `despacho`), lógica de triaje, datos iniciales y festivos
supabase/tests/              Pruebas SQL del triaje, el formulario y el panel (psql -1 -f)
supabase/functions/          Edge Functions: triaje (pública) y panel (abogado) + pruebas Deno
web/                         Formulario de consulta y bandeja de revisión
herramientas/                Servidor de desarrollo local
```

## Cómo probar en local

```
# 1. Postgres local con las migraciones aplicadas (ver supabase/tests)
# 2. Pruebas
cd supabase/functions && TEST_DB_URL=postgres://... deno test -A tests/
# 3. Web + funciones en http://localhost:8787
TEST_DB_URL=postgres://... deno run -A herramientas/servidor_local.ts
docs/                        Benchmark, producción y requerimientos
```
