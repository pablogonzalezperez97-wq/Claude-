# 03 · Requerimientos por tu parte

Lista de lo que necesito de ti para avanzar. Prioridad: 🔴 bloquea el arranque · 🟠 bloquea su fase · 🟢 mejora el resultado.
Puedes responder directamente en este documento o en el chat.

---

## A. Previos jurídico-profesionales (fuera del software, pero condicionan el diseño)

| # | Requisito | Prioridad | Estado |
|---|---|---|---|
| A1 | Revisar el contrato laboral: exclusividad, no concurrencia y compatibilidad con la actividad del empleador | 🔴 | ☐ |
| A2 | Colegiación como ejerciente confirmada (colegio y número) | 🔴 | ☐ |
| A3 | Seguro de responsabilidad civil profesional (cobertura y póliza) | 🔴 | ☐ |
| A4 | Régimen previsional: RETA o Mutualidad de la Abogacía | 🔴 | ☐ |
| A5 | Alta censal (modelo 036/037, epígrafe IAE 731) y régimen de IVA | 🔴 | ☐ |
| A6 | Manual y política de PBC: como asesor fiscal y en operaciones societarias eres sujeto obligado de la Ley 10/2010 | 🟠 | ☐ |
| A7 | Modelo de hoja de encargo y presupuesto (LO 5/2024 del Derecho de Defensa) | 🟠 | ☐ |

## B. Decisiones de negocio (configuración del sistema)

| # | Pregunta | Prioridad | Tu respuesta |
|---|---|---|---|
| B1 | Franjas disponibles (días y horas) | 🔴 | ✅ L y J 18:00–21:00 · M y X 19:15–21:15 (10 h/semana). *Supuesto: horario de tarde; confirmar.* |
| B2 | Duración de la consulta inicial y margen entre citas | 🔴 | ✅ 30 min + 15 min de margen |
| B3 | Tope de citas por semana | 🔴 | ✅ 5 |
| B4 | Precio de la consulta inicial; ¿se descuenta si hay encargo? | 🔴 | ✅ 50 €; no se descuenta, el asunto se presupuesta aparte |
| B5 | Política de cancelación (antelación para reembolso, reprogramaciones permitidas) | 🔴 | ✅ Reembolso con >24 h; 1 reprogramación gratuita |
| B6 | Modalidad: solo videollamada, presencial o ambas (¿dónde?) | 🔴 | ✅ Videollamada |
| B7 | Catálogo de servicios: lista cerrada de lo que **sí** haces, con precio orientativo | 🔴 | ✅ Generalista con foco mercantil; catálogo validado (doc 02, §4) |
| B8 | Lista de lo que **no** haces y a quién derivas (si tienes red de colegas) | 🟠 | ✅ Lista de derivación validada |
| B8b | Materias vetadas por tu empleo actual: sector de tu empleador, sus clientes o contrapartes habituales | 🔴 | ✅ Sin incompatibilidades |
| B9 | Ámbito geográfico (provincia, toda España, ¿clientes extranjeros?) | 🟠 | |
| B10 | Idiomas de atención | 🟢 | |
| B11 | Umbral de cuantía relevante para el scoring | 🟢 | |
| B12 | ¿Ofrecerás igualas mensuales en una fase 2? Rango de precio | 🟢 | |

## C. Contenido que solo puedes aportar tú

| # | Requisito | Prioridad | Nota |
|---|---|---|---|
| C1 | **Validación de las FAQ.** Yo redacto el borrador (≈40 preguntas) y tú revisas, corriges y apruebas cada una | 🟠 F4 | Es el activo crítico: el asistente solo dirá lo que apruebes |
| C2 | Cuestionario de triaje por materia: qué hechos y documentos necesitas para cada servicio | 🟠 F2 | Te daré una plantilla por servicio |
| C3 | Biografía profesional, foto y propuesta de valor | 🟠 F5 | Partimos de tu perfil |
| C4 | Marca: nombre comercial, logo y colores (o encargamos una identidad sencilla) | 🟠 F5 | |
| C5 | Revisión de los textos legales: aviso legal, privacidad, cookies, condiciones de contratación | 🟠 F5 | Te los redacto; la firma es tuya |
| C6 | Listado inicial de clientes y contrarios para la base de conflictos (si ya tienes historial) | 🟢 F2 | Con base jurídica para el tratamiento |

## D. Cuentas y accesos técnicos

Las cuentas se crean **a tu nombre**. Yo nunca necesito tus contraseñas: las claves se cargan como secretos del entorno.

| # | Servicio | Para qué | Prioridad | Estado |
|---|---|---|---|---|
| D1 | Dominio (p. ej. tunombre-abogado.es) | Web y email profesional | 🔴 | ☐ |
| D2 | Email profesional en el dominio (Google Workspace o similar) | Comunicaciones y Google Calendar | 🔴 | ☐ |
| D3 | Supabase: proyecto nuevo `despacho-captacion` (París, eu-west-3) | Base de datos | 🔴 | ⛔ Bloqueado: límite de 2 proyectos gratuitos |
| D4 | Stripe (verificación con NIF y cuenta bancaria) | Pagos | 🟠 F3 | ☐ |
| D5 | Cal.com (gratuito) vinculado a Google Calendar | Agenda | 🟠 F3 | ☐ |
| D6 | Clave de API de Anthropic, con límite de gasto | Asistente FAQ | 🟠 F4 | ☐ |
| D7 | Vercel (gratuito) | Alojamiento web | 🟠 F5 | ☐ |
| D8 | Proveedor de email transaccional (Resend), o uso de Gmail | Recordatorios | 🟢 | ☐ |

## E. Piloto

| # | Requisito | Prioridad |
|---|---|---|
| E1 | 5–10 personas de confianza que prueben el flujo completo y den feedback | 🟢 F6 |
| E2 | 2–3 casos reales anonimizados para probar el triaje | 🟢 F6 |

---

## Lo mínimo para que empiece a construir mañana

Bloque B cerrado ✅. Esquema de datos, triaje y conflictos escritos y probados en local. **Falta D3** (desbloquear el proyecto de Supabase) para desplegarlo.
