# JARVIS · entorno de control personal en el iPhone

App nativa de iOS que convierte el iPhone en el terminal principal de JARVIS.
Los agentes siguen trabajando en la nube y **Supabase pasa a ser la única fuente de verdad**,
de modo que la app, los widgets, Siri y el JARVIS Hub de claude.ai ven exactamente lo mismo.

```
              iPhone · app JARVIS (SwiftUI)
  HealthKit ──► healthkit-sync          (sustituye a Health Auto Export)
  Hoy / widgets ◄── jarvis-today        (readiness, sueño, carga, MIDAS, Donna, ULTRÓN)
  Siri / chat ──► jarvis-ask ──► Claude (la clave vive solo en Supabase)
  ARES · AURA · MIDAS · Donna ◄──► tablas con RLS (solo el propietario)
  Notificaciones ◄── jarvis-push ◄── INSERT en public.alerts
                          ▲
  Agentes programados (MIDAS 7:15 · Donna ×3 · AURA ×6 · ULTRÓN) escriben en Supabase
```

## Qué hay en este directorio

| Ruta | Qué es |
|---|---|
| `supabase/migrations/20261123120000_jarvis_core.sql` | Esquema único: MIDAS, Donna, AURA, ARES, briefings, alertas, registro de sincronización y dispositivos. RLS: solo el propietario (`private.owner`); los agentes entran con `service_role`. Aditivo: no toca datos existentes. |
| `supabase/functions/healthkit-sync` | Recibe agregados diarios, noches y entrenos de HealthKit. Misma nota de sueño y TRIMP que `apple-health-ingest`. |
| `supabase/functions/jarvis-today` | Una llamada con todo lo de hoy + comprobaciones de frescura de ULTRÓN. |
| `supabase/functions/jarvis-ask` | Pregunta libre a JARVIS con los datos de hoy y 14 días (Claude Opus 5.5, con reintento automático en otro modelo si declina). |
| `supabase/functions/jarvis-push` | Notificaciones APNs cuando un agente crea una alerta. |
| `supabase/functions/_shared` | Readiness, z-scores, CTL/ATL/TSB, sueño y TRIMP: una sola implementación. |
| `ios/` | App SwiftUI + widgets + atajos de Siri. Proyecto generado con XcodeGen. |

### La app (v0.1)

- **Hoy**: semáforo de ARES (readiness + TSB), sueño, HRV, FC en reposo, carga, portada de MIDAS, pedidos de Donna y avisos de ULTRÓN arriba del todo.
- **Agentes**: MIDAS (ediciones y fichas con fuentes), AURA (foto de comida con ración, grasa y cuánto comiste → la tarea de AURA calcula kcal y macros y borra la foto), Donna (pedidos).
- **Entreno**: tracker de ARES con la misma progresión que el web (sube tras 2 semanas en el tope de reps, baja un 10 % tras dos sesiones bajo el mínimo), pesos pautados y aviso de fin de descanso que suena con el iPhone en el bolsillo.
- **JARVIS**: chat con respuesta en voz alta opcional.
- **Siri**: «Briefing de JARVIS», «¿Cómo estoy hoy en JARVIS?», «Pregunta a JARVIS».
- **Widgets**: pantalla de inicio (pequeño y mediano) y pantalla de bloqueo.
- **Salud en segundo plano**: iOS despierta la app con datos nuevos de HRV, FC en reposo, sueño, entrenos y nutrición; además, una actualización periódica cada ~2 h.

## Puesta en marcha

### 1. Supabase (proyecto MCP, `eu-north-1`)

1. Aplicar la migración (`supabase db push`, o desde el panel SQL).
2. Crear tu usuario en **Authentication → Users** (correo, sin contraseña) y registrarlo como propietario:
   ```sql
   insert into private.owner (user_id) select id from auth.users where email = '<tu correo>';
   ```
3. Secretos de las funciones (**Edge Functions → Secrets**): `ANTHROPIC_API_KEY`; opcionales `USER_HR_MAX`, `USER_HR_REST`, `JARVIS_MODEL`.
   Para notificaciones: `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `PUSH_WEBHOOK_SECRET`.
4. Desplegar: `supabase functions deploy healthkit-sync jarvis-today jarvis-ask` y `supabase functions deploy jarvis-push --no-verify-jwt` (la valida su propia cabecera secreta).
5. **Database → Webhooks**: INSERT en `public.alerts` → `jarvis-push`, con cabecera `x-webhook-secret`.

### 2. iPhone (necesita un Mac)

1. Cuenta de **Apple Developer** (99 €/año): sin ella no hay HealthKit en segundo plano ni notificaciones, y la app caduca a los 7 días.
2. `brew install xcodegen`, copiar `ios/Config/Secrets.example.xcconfig` a `Secrets.xcconfig` y poner la URL y la clave **publicable** de Supabase.
3. En `ios/project.yml`: tu `DEVELOPMENT_TEAM` y un prefijo de bundle propio (y el mismo App Group en ambos targets).
4. `cd ios && xcodegen && open JARVIS.xcodeproj`, conectar el iPhone y ejecutar.
5. Primer arranque: acceso con código por correo → permisos de Salud y notificaciones → menú ⋯ → «Sincronizar 30 días de Salud».
6. Desactivar la automatización de Health Auto Export cuando la app esté sincronizando (si no, escribirían las dos).

## Fase 1b · que los agentes escriban en Supabase (pendiente de aprobar)

Las tres tareas programadas ya tienen el conector de Supabase. Falta cambiar sus instrucciones
para que escriban aquí (además de en el Hub mientras dure la transición):

- **MIDAS**: `editions` → `public.midas_editions`, `pills` → `public.midas_pills`, watchlist → `public.midas_watchlist`.
- **Donna**: cada pedido → `public.donna_orders` (upsert por id); cada alerta → `public.alerts` con `agent = 'donna'`.
- **AURA**: leer `public.aura_inbox` (status `pending`), escribir en `public.aura_meals`, borrar la fila del inbox.
- **ULTRÓN** (nueva tarea, cada mañana): comprobar frescura en `sync_log` y `daily_metrics`, y crear alertas en `public.alerts`.
- **Migración de datos**: copiar del Hub el histórico de ARES (sesiones), las comidas de AURA y la watchlist.

## Notas de seguridad

- Datos de salud y datos derivados del correo: categoría especial del RGPD. El proyecto está en la UE; RLS en todas las tablas nuevas; la app solo lleva la clave publicable; la de Anthropic y la `service_role` viven en Supabase.
- `Jarvis-mcp` recibe el token en la ruta de la URL, así que aparece en los registros de peticiones: conviene rotarlo y pasarlo a cabecera.
- Los conectores «Jarvis-mcp» y «Jarvito» apuntan a la misma función; uno de ellos tiene un espacio al principio del token en la URL. Basta con uno.
