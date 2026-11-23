# 01 · Benchmark: modelos de gestión análogos

Objetivo: identificar negocios de servicio profesional con **capacidad horaria limitada** que ya resolvieron captación, triaje, agenda y FAQ automatizados, y extraer qué es extrapolable a un despacho mercantil-tributario de tarde.

> Nota de método: buena parte de las cifras de eficacia proceden del propio proveedor (material comercial). Se usan como orientación, no como dato verificado.

---

## 1. Sanidad privada — Doctoralia (agenda + cobro anticipado)

| Qué hacen | Cómo lo extrapolamos |
|---|---|
| Reserva online presencial o por videollamada; la agenda sigue activa con la consulta cerrada | La agenda solo expone **franjas de tarde**, pero acepta reservas 24/7 |
| Recordatorios automáticos por email/SMS/WhatsApp | Recordatorios a −24 h y −2 h, con enlace para reprogramar |
| Pago anticipado, parcial o completo, configurable por servicio | **Consulta inicial prepagada** (o señal) por tipo de servicio |
| Dicen reducir ausencias hasta un 50 % con prepago (dato del proveedor) | El prepago es el principal filtro anti-curiosos y anti-ausencias |
| Crítica de usuarios: comisiones de pago elevadas | Pasarela propia (Stripe) en vez de marketplace con comisión |

## 2. Estética y peluquería — Booksy (política de no-show)

| Qué hacen | Cómo lo extrapolamos |
|---|---|
| Depósito al reservar, que el negocio fija por servicio | Importe de consulta fijado por tipo (p. ej. societario ≠ requerimiento AEAT) |
| Cargo por no presentarse según una política publicada | **Política de cancelación** visible antes de pagar: reembolso si cancela con >24 h |
| Política visible en el perfil | Texto en la landing y en el checkout, con aceptación expresa |
| Requiere verificar la identidad en Stripe | Mismo requisito: alta en Stripe con NIF y cuenta del despacho |

⚠ Diferencia jurídica: el cliente es consumidor en muchos casos, así que el TRLGDCU exige penalizaciones proporcionadas y gestionar el **derecho de desistimiento** en servicios contratados a distancia. Hay que recoger el consentimiento expreso para prestar el servicio dentro de los 14 días.

## 3. Asesoría fiscal online — TaxDown (IA + asesor humano)

| Qué hacen | Cómo lo extrapolamos |
|---|---|
| Asistente IA ("Luz") abierto a todos; el asesor humano solo con plan de pago | **Asistente FAQ gratuito → asesoramiento solo en cita pagada** |
| Revisión humana de cada declaración antes de presentarla | Nada sale firmado sin tu revisión: la IA prepara y tú validas |
| Chat fiscal gratuito como herramienta de captación (AsesorIA) | Las FAQ y las calculadoras sencillas funcionan como imán de leads |
| Suscripciones para romper la estacionalidad de la campaña de renta | **Fase 2:** igualas mensuales para autónomos y pymes (ingresos recurrentes) |
| La IA multiplica la capacidad del asesor (dato del proveedor) | Resumen automático del caso antes de cada cita |

## 4. Software jurídico — Clio Grow (intake legal)

Es el análogo más directo; el sector es otro mercado (anglosajón).

| Qué hacen | Cómo lo extrapolamos |
|---|---|
| **Comprobación de conflictos** en el intake contra todo el registro; el humano revisa las coincidencias | Cruce automático de la contraparte con clientes y contrarios; las coincidencias te llegan para decidir |
| Página de reservas con pago opcional y confirmación por email | Igual |
| La IA responde, filtra por encaje y conflictos y agenda si el despacho lo permite | El agente agenda **solo** si el caso supera el triaje; los dudosos van a tu cola de revisión |
| Formularios de intake con recordatorios hasta completarlos | Recordatorio si falta documentación antes de la cita |
| El lead convertido pasa a expediente con sus datos | Lead → cliente → asunto, sin volver a teclear |

## 5. Inmobiliaria — chatbots de cualificación 24/7

| Qué hacen | Cómo lo extrapolamos |
|---|---|
| Atención fuera de horario y captación sin personal | Atención durante tu jornada principal |
| **Scoring transparente por puntos** (presupuesto, plazo, preferencias): caliente, templado o frío | Puntuación por materia, urgencia (plazo legal), cuantía y documentación aportada |
| Conexión con Cal.com o Calendly para reservar visitas | Conexión con Cal.com y Google Calendar |

## 6. Psicología online — Unobravo, BetterHelp (cuestionario y emparejamiento)

| Qué hacen | Cómo lo extrapolamos |
|---|---|
| Cuestionario previo que orienta la primera sesión | Cuestionario por materia que adelanta los hechos y los documentos |
| Asignación al profesional adecuado | Sirve hoy para **derivar** lo que no es tuyo (penal, familia); mañana, para repartir con colaboradores |
| Adhesión a códigos de buenas prácticas del colegio profesional | Cumplimiento visible del Código Deontológico en la web (sello de confianza) |

---

## Síntesis: patrón común extrapolable

1. **Escaparate 24/7, servicio en franja limitada.** La reserva nunca duerme; tu agenda sí.
2. **Información gratis, criterio de pago.** La FAQ y la IA informan; el asesoramiento sobre el caso concreto se paga.
3. **Fricción deliberada:** prepago, cuestionario y documentos. Filtra y prepara la cita.
4. **Triaje con reglas explicables**, no una caja negra. Encaja además con la transparencia que exige el Reglamento de IA.
5. **Humano en el bucle** para todo lo que comprometa: conflictos, aceptación del encargo y opinión jurídica.
6. **Recurrencia** como segunda fase: igualas al estilo de TaxDown.

## Fuentes

- Doctoralia Pro — funcionalidades y pagos: https://pro.doctoralia.es/productos/funcionalidades-populares/reserva-online-de-cita-0 · https://pro.doctoralia.es/hubfs/ES%20CM%202025/es-cm-doc-ebook-dp-payments.pdf · https://pabau.com/es/blog/precios-de-doctoralia-pro/ · https://www.capterra.com/p/253301/Doctoralia-Pro/reviews/
- Booksy — protección contra ausencias y política de cancelación: https://biz.booksy.com/es-es/funcionalidades/proteccion-contra-ausencias · https://biz.booksy.com/es-es/blog/politica-de-cancelacion-y-no-show-para-salones
- TaxDown — modelo: https://taxdown.es/sobre-taxdown · https://taxdown.es/precios-v3 · https://iberianlawyer.com/?p=194043 · https://ecosistemastartup.com/?p=39121
- Clio Grow — intake, conflictos y reservas: https://www.clio.com/ca/grow/ · https://www.clio.com/features/appointment-bookings/ · https://www.clio.com/ca/features/legal-workflow-automation-software/
- Inmobiliaria — scoring y agenda: https://www.spurnow.com/id/blogs/ai-chatbot-for-real-estate-lead-qualification · https://elevenlabs.io/chatbot/real-estate · https://www.lowcode.agency/blog/how-to-build-an-ai-lead-qualification-chatbot-for-real-estate
- Psicología online: https://www.psyciencia.com/?p=90216 · https://www.unobravo.com/es/psicologo-online-chat
