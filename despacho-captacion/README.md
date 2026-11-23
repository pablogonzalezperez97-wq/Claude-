# Despacho de tarde · Sistema de captación y agenda

Sistema para un despacho de abogado generalista, con práctica centrada en derecho mercantil, a tiempo parcial. Durante el día capta, informa, filtra, cobra y agenda; por la tarde el abogado atiende con el expediente ya preparado.

## Documentación

1. [Benchmark de modelos análogos](docs/01-benchmark-modelos-analogos.md): qué hacen Doctoralia, Booksy, TaxDown, Clio Grow, los chatbots inmobiliarios y las plataformas de psicología online, y qué extrapolamos.
2. [Estructura de producción](docs/02-estructura-produccion.md): módulos, flujo, modelo de datos, scoring, salvaguardas de la IA, fases y criterios de aceptación.
3. [Requerimientos por tu parte](docs/03-requerimientos-cliente.md): checklist priorizado de decisiones, contenidos y cuentas.

## Estado

- [x] F0 · Benchmark y estructura de producción
- [x] F0 · Decisiones de negocio (bloque B cerrado)
- [x] F1 · Esquema de datos: migraciones en `supabase/migrations/`, probadas en PostgreSQL local
- [x] F2 (base) · Triaje, scoring, derivación y comprobación de conflictos en la base de datos
- [ ] F1 · Despliegue en Supabase (bloqueado: límite de proyectos gratuitos)
- [ ] F2 · Formulario de triaje y cola de revisión

## Estructura

```
config/negocio.yaml          Parámetros del despacho (fuente única de verdad)
supabase/migrations/         Esquema, lógica de triaje y datos iniciales
docs/                        Benchmark, producción y requerimientos
```
