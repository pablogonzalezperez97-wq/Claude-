# 02 · Estructura de producción

Versión: híbrida (landing propia + asistente IA + Supabase + Cal.com + Stripe).
Principio rector: **nada que comprometa al abogado sale sin validación humana.**

---

## 1. Módulos del sistema

| # | Módulo | Función | Tecnología prevista |
|---|---|---|---|
| M1 | Landing | Servicios, precios orientativos, confianza, entrada al asistente | Next.js en Vercel o HTML estático |
| M2 | Asistente FAQ | Responde **solo** desde la base de FAQ validada; se identifica como IA; deriva a cita | API de Claude + base de FAQ en Supabase |
| M3 | Triaje | Cuestionario dinámico por materia, alerta de plazos y scoring por puntos | Formulario propio + reglas en el backend |
| M4 | Conflictos | Cruce de la contraparte y del propio cliente con el registro histórico | Supabase (búsqueda por NIF y por similitud de nombre) |
| M5 | Pago | Consulta prepagada, política de cancelación, consentimiento de desistimiento | Stripe Checkout |
| M6 | Agenda | Franjas de tarde, topes, márgenes y videollamada | Cal.com + Google Calendar |
| M7 | Expediente previo | Resumen IA del caso + documentos, enviado antes de la cita | Supabase Storage + email |
| M8 | Comunicaciones | Confirmación, recordatorios, documentación pendiente y seguimiento | Email transaccional (Resend o Gmail) |
| M9 | Panel del abogado | Cola de revisión (dudosos y conflictos), agenda y leads | Panel web protegido |
| M10 | Cumplimiento | Registro de consentimientos, RGPD, activación de diligencia debida PBC, logs | Transversal |

## 2. Flujo del cliente (camino feliz)

```
Visita → Asistente FAQ ─(caso concreto)→ Triaje → Scoring
   ├─ No encaja           → respuesta de derivación + cierre
   ├─ Dudoso o conflicto  → cola de revisión del abogado (M9) → aceptar o rechazar
   └─ Encaja              → Pago (M5) → Reserva (M6) → Subida de documentos
                             → Recordatorios (M8) → Expediente previo (M7) → CITA
                             → Hoja de encargo y presupuesto → Cliente
```

## 3. Modelo de datos inicial (borrador)

- `clientes` (id, tipo persona física/jurídica, nombre, NIF, email, teléfono, consentimientos, creado_en)
- `contrapartes` (id, nombre, NIF, asunto_id)
- `leads` (id, cliente_id, materia, subtipo, urgencia, fecha_limite, cuantía, puntuación, estado, origen)
- `conflictos` (id, lead_id, coincidencia, tipo, estado_revisión, decidido_por, decidido_en)
- `citas` (id, lead_id, inicio, fin, modalidad, estado, cal_id, pago_id)
- `pagos` (id, lead_id, importe, estado, stripe_id, reembolsable_hasta)
- `documentos` (id, lead_id, ruta_storage, tipo, subido_en)
- `faq` (id, materia, pregunta, respuesta, fuente_normativa, validada, versión, revisar_en)
- `interacciones_ia` (id, sesión, pregunta, respuesta, faq_ids_usadas, derivada, creado_en) — trazabilidad
- `asuntos` (id, cliente_id, hoja_encargo_firmada, presupuesto, estado) — fase 2

## 4. Reglas de scoring (propuesta inicial, para validar)

| Criterio | Puntos |
|---|---|
| Materia dentro del catálogo (mercantil o tributario) | +30 (fuera del catálogo = derivar) |
| Plazo legal en curso (requerimiento, recurso) | +20; si vence en ≤5 días hábiles, alerta inmediata |
| Cuantía o valor estimado sobre el umbral X | +15 |
| Documentación clave aportada | +15 |
| Empresa o autónomo (potencial recurrente) | +10 |
| Ha aceptado precio y política | +10 |
| **≥70 agenda directa · 40–69 revisión · <40 respuesta estándar** | |

## 5. Salvaguardas del asistente IA (requisitos no negociables)

1. Aviso de IA en el primer mensaje y de forma permanente en la interfaz (Reglamento de IA, art. 50).
2. Responde solo con las FAQ validadas (recuperación cerrada). Si no hay cobertura, dice "no lo sé" y deriva.
3. Detecta el caso concreto ("en mi caso…", datos personales, importes) y deriva a cita sin opinar.
4. No recoge datos sensibles en el chat; los datos del caso van al triaje, con base jurídica e información RGPD.
5. Proveedor configurado sin retención ni entrenamiento con los datos; alojamiento en la UE donde sea posible.
6. Registro de cada respuesta con las FAQ usadas, para auditar y corregir.
7. Descargo visible: "Información general; no constituye asesoramiento jurídico ni crea relación abogado-cliente."

## 6. Fases y entregables

| Fase | Contenido | Entregable | Depende de ti (ver doc 03) |
|---|---|---|---|
| **F0 · Fundamentos** (sem. 1) | Decisiones de negocio, cuentas, dominio | Ficha de configuración cerrada | Bloque A y B |
| **F1 · Núcleo de datos** (sem. 1–2) | Supabase: esquema, seguridad (RLS), almacenamiento | Base desplegada + migraciones en el repo | Cuenta Supabase |
| **F2 · Triaje + conflictos** (sem. 2) | Formulario, scoring, cruce de conflictos, cola de revisión | Triaje funcional en pruebas | Catálogo de servicios, reglas |
| **F3 · Pago + agenda** (sem. 3) | Stripe, Cal.com, política de cancelación, recordatorios | Reserva pagada de extremo a extremo (modo test) | Stripe, Cal.com, precios |
| **F4 · Asistente FAQ** (sem. 3–4) | Base de FAQ, agente, salvaguardas, registros | Asistente en pruebas cerradas | **Validación de las FAQ** |
| **F5 · Landing + legales** (sem. 4) | Web, aviso legal, privacidad, cookies, condiciones | Web en preproducción | Textos legales, marca |
| **F6 · Piloto** (sem. 5) | 5–10 usuarios de confianza, ajustes | Informe de piloto | Testers |
| **F7 · Lanzamiento** | Producción, analítica, primeras campañas | Sistema en vivo | Visto bueno final |
| **Fase 2** | Hoja de encargo con firma, igualas, módulo PBC completo, facturación | — | — |

## 7. Criterios de aceptación del MVP

- [ ] Un usuario puede pasar de la FAQ a una cita pagada en menos de 5 minutos.
- [ ] Ninguna cita entra fuera de las franjas definidas ni por encima del tope semanal.
- [ ] Toda coincidencia de conflicto bloquea la agenda directa y aparece en la cola de revisión.
- [ ] Un plazo que vence en ≤5 días hábiles te genera una alerta inmediata.
- [ ] El asistente rechaza opinar sobre casos concretos en el 100 % de una batería de 30 preguntas trampa.
- [ ] Recibes el expediente previo al menos 2 h antes de cada cita.
- [ ] Los consentimientos (RGPD, condiciones, desistimiento) quedan registrados con fecha y versión.
