# 04 · Plataforma completa: gestión, portal del cliente y asistente de voz

Evolución del sistema de captación hacia una plataforma con **tres caras sobre una misma base de datos**:

```
                    ┌──────────────────────────── Supabase (UE) ────────────────────────────┐
 Visitante ──► Asistente IA (voz/texto) ──► Triaje + conflictos ──► Cita pagada ──┐        │
                     │  detecta oportunidades                                     ▼        │
                     └──────────────► Oportunidades (las valida el abogado)    AGENDA      │
                                                                                 ▲        │
 Cliente ───► PORTAL: sus expedientes · documentos compartidos · mensajes · pagos · citas  │
                                                                                 │        │
 Abogado ───► PANEL: dashboard · clientes · expedientes · agenda · tareas · documentos ·   │
              finanzas · solicitudes · derivaciones · oportunidades · asistente IA         │
                    └──────────────────────────────────────────────────────────────────────┘
```

## 1. Vista del abogado (administrador)

| Módulo | Contenido | Estado |
|---|---|---|
| Dashboard | Vencimientos y audiencias a 7 días, citas, expedientes activos por estado, tareas atrasadas, pendiente de cobro, ingresos y gastos del mes, solicitudes y oportunidades por revisar | ✅ datos (`panel_dashboard`) · ⏳ interfaz |
| Clientes | Directorio, ficha, expedientes, acceso al portal | ✅ datos · ⏳ interfaz |
| Expedientes | Número automático (2026/0001), materia, contraparte, órgano, procedimiento, estado, responsable, honorarios, hoja de encargo, diligencia PBC, notas internas | ✅ datos · ⏳ interfaz |
| Agenda | Vencimientos, audiencias, reuniones, recordatorios y **citas del embudo, que entran solas** | ✅ datos · ⏳ interfaz |
| Tareas | Por expediente, con fecha y responsable; atrasadas destacadas | ✅ datos · ⏳ interfaz |
| Documentos | Por expediente, categoría, revisado, compartido con el cliente, huella SHA-256, **registro de accesos** | ✅ datos · ⏳ almacenamiento e interfaz |
| Finanzas | Honorarios, provisiones de fondos, suplidos y gastos, con IVA desglosado; cobrado / pendiente | ✅ datos · ⏳ interfaz |
| Solicitudes y derivaciones | Bandeja de revisión y derivaciones agrupadas por área | ✅ funcionando en local |
| Oportunidades | Necesidades adicionales detectadas por la IA con la cita literal que las justifica | ✅ datos · ⏳ interfaz |

## 2. Portal del cliente

El cliente accede con su email (enlace de acceso, sin contraseñas que recordar) y **solo** ve:

- sus expedientes y su estado;
- sus próximas audiencias y citas (no los vencimientos internos);
- los documentos que el abogado marque como compartidos (y puede subir los suyos);
- sus pagos pendientes (con pago online);
- un canal de mensajes seguro con el abogado;
- reserva de nuevas citas, que entran en la agenda del abogado.

**Nunca** ve tareas, notas internas, oportunidades, transcripciones ni datos de otros clientes. Probado (`supabase/tests/pruebas_gestion_portal.sql`): aislamiento entre clientes, columna de notas bloqueada y escritura solo en sus expedientes.

## 3. Asistente IA de primera atención (voz del abogado)

### Qué hace
1. **Recibe** al visitante por la web (texto o voz) y, en una fase posterior, por teléfono.
2. **Se identifica como IA** desde el primer segundo, también cuando usa la voz del abogado.
3. **Responde dudas generales** solo con preguntas frecuentes validadas.
4. **Entrevista** al cliente siguiendo el cuestionario de triaje y rellena la solicitud: tipo de cliente, materia, hechos, plazos, cuantía y parte contraria.
5. **Detecta oportunidades**: otras necesidades del cliente dentro del catálogo, siempre con la cita literal que las justifica. Por ejemplo, la sociedad no tiene pacto de socios, no se levantan actas o hay deudas de clientes sin reclamar.
6. **Agenda** la consulta pagada si el caso encaja, o lo envía a tu bandeja.
7. **Te entrega** un resumen, la transcripción y las oportunidades detectadas antes de la cita.

### Cross-selling con garantías (criterio deontológico)
- La IA **detecta**, pero **el abogado decide**. Una oportunidad nace como `detectada`, y solo pasa a `ofrecida` cuando el abogado la valida.
- Ante el cliente, como mucho una mención neutra: "En la consulta el abogado podrá revisar también la situación de las actas sociales". Sin precios, sin urgencia artificial y sin presión.
- Solo se proponen materias del catálogo, cada una con evidencia literal (no hay inferencias sin respaldo).
- Toda conversación queda guardada para auditoría (`conversaciones_ia`).

### Voz del abogado
- **Clonación con consentimiento propio**: necesitas grabar unos minutos de audio limpio; la voz queda en una cuenta a tu nombre.
- **Transparencia obligatoria** (Reglamento de IA, art. 50): aviso de IA al inicio y contenido sintético marcado. La voz clonada no puede inducir a pensar que habla el abogado en persona.
- **Cadena técnica**: voz a texto → Claude (razonamiento y entrevista) → texto a voz con tu voz. Tras la web, se puede añadir telefonía.
- **No asesora**: ante un caso concreto, deriva a la cita igual que el formulario.

### Protección de datos
- Grabación y transcripción solo con consentimiento expreso e información previa (art. 13 RGPD).
- Minimización: si aparecen datos de salud u otros especialmente sensibles, se pide no detallarlos y se reconduce a la cita.
- Plazo de conservación definido por conversación (`conservar_hasta`).
- Proveedores con contrato de encargado, alojamiento en la UE donde sea posible y sin entrenar modelos con los datos.

## 4. Seguridad de los archivos
- Almacenamiento privado (Supabase Storage) con acceso solo mediante enlaces firmados de corta duración.
- Huella SHA-256 de cada documento para acreditar su integridad.
- Registro de quién ve, descarga o sube cada documento.
- Visibilidad por documento: por defecto **no** se comparte con el cliente.
- Recomendado en producción: plan Pro (copias diarias) y doble factor en la cuenta del abogado.

## 5. Fases

| Fase | Entregable | Depende de |
|---|---|---|
| **P1** | Panel del abogado: dashboard, clientes, expedientes, agenda, tareas y finanzas | Despliegue en Supabase (bloqueado) |
| **P2** | Documentos seguros (almacenamiento, compartir, registro de accesos) | P1 |
| **P3** | Portal del cliente: login, expedientes, documentos, mensajes y reserva de citas | P1-P2 |
| **P4** | Reserva y pago (Cal.com + Stripe) conectados a la agenda | Cuentas de Stripe y Cal.com |
| **P5** | Asistente IA por texto: preguntas frecuentes, entrevista, triaje y oportunidades | Preguntas frecuentes validadas y clave de API de Anthropic |
| **P6** | Voz del abogado en el asistente web | Muestras de voz y cuenta del proveedor de voz |
| **P7** | Canal telefónico | Número de teléfono y proveedor de telefonía |

## 6. Nota sobre el anuncio de referencia
Las capturas muestran un producto comercial ("claridadyaccion"). No copiamos su diseño ni su marca: construimos un sistema propio con funciones equivalentes y adaptado al derecho español (IVA, días hábiles de La Rioja, PBC, secreto profesional, Reglamento de IA). Antes de seguir construyendo merece la pena valorarlo como alternativa de compra frente a desarrollo propio: lo diferencial de esta plataforma es el embudo con triaje, conflictos y asistente de voz, que esas herramientas no suelen traer.
