-- =====================================================================
-- Plataforma de gestión del despacho + portal del cliente + oportunidades (IA)
--   Vista ADMIN (abogado): expedientes, tareas, agenda, finanzas, documentos, dashboard.
--   Vista CLIENTE (portal): sus expedientes, documentos compartidos, citas, mensajes y pagos.
--   Oportunidades: necesidades adicionales detectadas por el asistente IA (cross-selling),
--   que SIEMPRE valida el abogado antes de ofrecerlas.
-- =====================================================================

set local search_path = despacho, extensions, public;

-- ---------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------
create type estado_expediente as enum ('abierto', 'en_tramite', 'pendiente_revision', 'urgente', 'suspendido', 'cerrado');
create type tipo_evento       as enum ('vencimiento', 'audiencia', 'reunion', 'cita_cliente', 'recordatorio');
create type tipo_movimiento   as enum ('honorario', 'provision_fondos', 'suplido', 'gasto');
create type estado_movimiento as enum ('pendiente', 'cobrado', 'pagado', 'anulado');
create type estado_oportunidad as enum ('detectada', 'validada', 'ofrecida', 'aceptada', 'descartada');
create type autor_mensaje     as enum ('cliente', 'abogado', 'sistema');

-- ---------------------------------------------------------------------
-- Clientes con acceso al portal
-- ---------------------------------------------------------------------
alter table clientes add column user_id uuid unique;   -- auth.users.id del cliente (portal)

create or replace function es_cliente_de(p_cliente uuid)
returns boolean language sql stable security definer set search_path = despacho as $$
  select exists (select 1 from despacho.clientes where id = p_cliente and user_id = auth.uid());
$$;

-- ---------------------------------------------------------------------
-- Expedientes
-- ---------------------------------------------------------------------
create sequence expediente_num_seq;

create table expedientes (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique
    default to_char(now(), 'YYYY') || '/' || lpad(nextval('despacho.expediente_num_seq')::text, 4, '0'),
  cliente_id uuid not null references clientes(id) on delete restrict,
  lead_id uuid references leads(id) on delete set null,
  materia_codigo text references materias(codigo),
  titulo text not null,                     -- "García c/ Aseguradora del Plata S.A."
  contraparte text,
  organo text,                              -- juzgado, AEAT, registro...
  procedimiento text,                       -- nº de autos o referencia administrativa
  estado estado_expediente not null default 'abierto',
  responsable uuid,                         -- abogado responsable
  honorarios_pactados numeric(12,2),        -- presupuesto aceptado (IVA incl.)
  hoja_encargo_firmada boolean not null default false,
  pbc_diligencia_ok boolean,                -- diligencia debida Ley 10/2010 cuando aplique
  notas_internas text,                      -- NUNCA visibles para el cliente
  abierto_en date not null default current_date,
  cerrado_en date,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
create index expedientes_cliente_idx on expedientes (cliente_id);
create index expedientes_estado_idx on expedientes (estado);
create trigger expedientes_act before update on expedientes for each row execute function tocar_actualizado();

-- ---------------------------------------------------------------------
-- Tareas (internas) y agenda
-- ---------------------------------------------------------------------
create table tareas (
  id uuid primary key default gen_random_uuid(),
  expediente_id uuid references expedientes(id) on delete cascade,
  titulo text not null,
  vence_en date,
  responsable uuid,
  hecha boolean not null default false,
  hecha_en timestamptz,
  creado_en timestamptz not null default now()
);
create index tareas_pendientes_idx on tareas (vence_en) where not hecha;

create table eventos (
  id uuid primary key default gen_random_uuid(),
  tipo tipo_evento not null,
  titulo text not null,
  expediente_id uuid references expedientes(id) on delete cascade,
  cita_id uuid references citas(id) on delete cascade,
  inicio timestamptz not null,
  fin timestamptz,
  lugar text,
  hecho boolean not null default false,
  creado_en timestamptz not null default now(),
  check (fin is null or fin > inicio)
);
create index eventos_inicio_idx on eventos (inicio);

-- Cada cita del embudo aparece automáticamente en la agenda del abogado.
create or replace function cita_a_agenda()
returns trigger language plpgsql security definer set search_path = despacho as $$
begin
  if tg_op = 'INSERT' then
    insert into eventos (tipo, titulo, cita_id, inicio, fin, lugar)
    select 'cita_cliente', 'Consulta inicial · ' || c.nombre, new.id, new.inicio, new.fin, new.modalidad::text
    from leads l join clientes c on c.id = l.cliente_id where l.id = new.lead_id;
  elsif new.estado in ('cancelada') then
    delete from eventos where cita_id = new.id;
  else
    update eventos set inicio = new.inicio, fin = new.fin, hecho = (new.estado = 'realizada') where cita_id = new.id;
  end if;
  return new;
end $$;
create trigger citas_agenda after insert or update on citas for each row execute function cita_a_agenda();

-- ---------------------------------------------------------------------
-- Finanzas por expediente (importes con IVA desglosado)
-- ---------------------------------------------------------------------
create table movimientos (
  id uuid primary key default gen_random_uuid(),
  expediente_id uuid references expedientes(id) on delete restrict,
  tipo tipo_movimiento not null,
  concepto text not null,
  base_eur numeric(12,2) not null,
  iva_pct numeric(4,2) not null default 21,     -- suplidos y gastos suelen ir al 0 %
  total_eur numeric(12,2) generated always as (round(base_eur * (1 + iva_pct / 100), 2)) stored,
  estado estado_movimiento not null default 'pendiente',
  fecha date not null default current_date,
  vence_en date,
  factura_ref text,
  pago_id uuid references pagos(id),            -- cobros online (Stripe)
  creado_en timestamptz not null default now(),
  check (base_eur >= 0)
);
create index movimientos_exp_idx on movimientos (expediente_id);
create index movimientos_pend_idx on movimientos (estado) where estado = 'pendiente';

-- ---------------------------------------------------------------------
-- Documentos: vinculados a expediente, con control de visibilidad e integridad
-- ---------------------------------------------------------------------
alter table documentos
  add column expediente_id uuid references expedientes(id) on delete cascade,
  add column categoria text,                         -- escrito, notificación, contrato, prueba...
  add column revisado boolean not null default false,
  add column visible_cliente boolean not null default false,
  add column sha256 text,                            -- huella para acreditar integridad
  add column subido_por text not null default 'abogado' check (subido_por in ('abogado', 'cliente'));
alter table documentos alter column lead_id drop not null;
alter table documentos add constraint documentos_vinculo check (lead_id is not null or expediente_id is not null);

-- Registro de accesos a documentos (quién y cuándo): trazabilidad del secreto profesional.
create table accesos_documentos (
  id bigint generated always as identity primary key,
  documento_id uuid not null references documentos(id) on delete cascade,
  usuario uuid,
  accion text not null check (accion in ('ver', 'descargar', 'subir', 'borrar')),
  creado_en timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Mensajes del portal (canal seguro abogado-cliente)
-- ---------------------------------------------------------------------
create table mensajes (
  id uuid primary key default gen_random_uuid(),
  expediente_id uuid not null references expedientes(id) on delete cascade,
  autor autor_mensaje not null,
  texto text not null check (length(texto) between 1 and 5000),
  leido boolean not null default false,
  creado_en timestamptz not null default now()
);
create index mensajes_exp_idx on mensajes (expediente_id, creado_en);

-- ---------------------------------------------------------------------
-- Oportunidades detectadas por el asistente IA (cross-selling con validación humana)
-- ---------------------------------------------------------------------
create table oportunidades (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid references leads(id) on delete cascade,
  expediente_id uuid references expedientes(id) on delete cascade,
  materia_codigo text references materias(codigo),
  necesidad text not null,          -- "No tiene pacto de socios y hay 3 socios"
  evidencia text not null,          -- cita literal de la conversación que la justifica
  confianza real check (confianza between 0 and 1),
  estado estado_oportunidad not null default 'detectada',
  decidido_por uuid,
  decidido_en timestamptz,
  creado_en timestamptz not null default now(),
  check (lead_id is not null or expediente_id is not null)
);
create index oportunidades_estado_idx on oportunidades (estado);

-- Grabaciones/transcripciones del primer contacto con el asistente (voz o texto).
create table conversaciones_ia (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid references leads(id) on delete set null,
  canal text not null check (canal in ('web_texto', 'web_voz', 'telefono')),
  consentimiento_grabacion boolean not null default false,
  aviso_ia_dado boolean not null default false,     -- art. 50 Reglamento de IA
  transcripcion text,
  resumen text,                                     -- resumen para el abogado
  duracion_s integer,
  conservar_hasta date,                             -- plazo de conservación (RGPD)
  creado_en timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Convertir un lead aceptado en expediente
-- ---------------------------------------------------------------------
create or replace function abrir_expediente(p_lead uuid, p_titulo text, p_honorarios numeric default null)
returns uuid language plpgsql security invoker set search_path = despacho, public as $$
declare v_exp uuid;
begin
  if not es_abogado() then raise exception 'no_autorizado'; end if;
  insert into expedientes (cliente_id, lead_id, materia_codigo, titulo, contraparte, honorarios_pactados, responsable)
  select l.cliente_id, l.id, l.materia_codigo, p_titulo,
         (select string_agg(nombre, ', ') from contrapartes where lead_id = l.id),
         p_honorarios, auth.uid()
  from leads l where l.id = p_lead
  returning id into v_exp;
  if v_exp is null then raise exception 'lead_no_encontrado'; end if;
  update leads set estado = 'convertido' where id = p_lead;
  update oportunidades set expediente_id = v_exp where lead_id = p_lead;
  return v_exp;
end $$;

-- ---------------------------------------------------------------------
-- Dashboard del abogado
-- ---------------------------------------------------------------------
create or replace function panel_dashboard()
returns jsonb language sql stable security invoker set search_path = despacho, public as $$
  select jsonb_build_object(
    'vencimientos_7d', (select count(*) from eventos where tipo = 'vencimiento' and not hecho
                          and inicio < now() + interval '7 days'),
    'audiencias_7d',   (select count(*) from eventos where tipo = 'audiencia' and not hecho
                          and inicio between now() and now() + interval '7 days'),
    'citas_7d',        (select count(*) from eventos where tipo = 'cita_cliente' and not hecho
                          and inicio between now() and now() + interval '7 days'),
    'expedientes_activos', (select count(*) from expedientes where estado <> 'cerrado'),
    'expedientes_por_estado', (select coalesce(jsonb_object_agg(estado, n), '{}') from
                                 (select estado, count(*) n from expedientes where estado <> 'cerrado' group by 1) s),
    'tareas_atrasadas', (select count(*) from tareas where not hecha and vence_en < current_date),
    'pendiente_cobro_eur', (select coalesce(sum(total_eur), 0) from movimientos
                              where estado = 'pendiente' and tipo in ('honorario', 'provision_fondos')),
    'ingresos_mes_eur', (select coalesce(sum(total_eur), 0) from movimientos
                           where estado = 'cobrado' and tipo in ('honorario', 'provision_fondos')
                             and date_trunc('month', fecha) = date_trunc('month', current_date)),
    'gastos_mes_eur', (select coalesce(sum(total_eur), 0) from movimientos
                         where tipo in ('gasto', 'suplido') and estado <> 'anulado'
                           and date_trunc('month', fecha) = date_trunc('month', current_date)),
    'solicitudes_pendientes', (select count(*) from leads where estado in ('revision', 'apto')),
    'oportunidades_por_validar', (select count(*) from oportunidades where estado = 'detectada')
  );
$$;

-- ---------------------------------------------------------------------
-- Portal del cliente: solo lo suyo y solo lo compartible
-- ---------------------------------------------------------------------
create or replace function portal_resumen()
returns jsonb language sql stable security invoker set search_path = despacho, public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'numero', e.numero, 'titulo', e.titulo, 'estado', e.estado, 'abierto_en', e.abierto_en,
    'proximos_eventos', coalesce((select jsonb_agg(jsonb_build_object('tipo', ev.tipo, 'titulo', ev.titulo, 'inicio', ev.inicio) order by ev.inicio)
                                  from eventos ev where ev.expediente_id = e.id and not ev.hecho
                                    and ev.tipo in ('audiencia', 'cita_cliente') and ev.inicio > now()), '[]'),
    'documentos', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'nombre', d.nombre_original, 'categoria', d.categoria, 'subido_en', d.subido_en) order by d.subido_en desc)
                            from documentos d where d.expediente_id = e.id and d.visible_cliente), '[]'),
    'pagos_pendientes', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'concepto', m.concepto, 'total_eur', m.total_eur, 'vence_en', m.vence_en))
                                  from movimientos m where m.expediente_id = e.id and m.estado = 'pendiente'
                                    and m.tipo in ('honorario', 'provision_fondos')), '[]'),
    'mensajes_no_leidos', (select count(*) from mensajes ms where ms.expediente_id = e.id and ms.autor = 'abogado' and not ms.leido)
  ) order by e.abierto_en desc), '[]'::jsonb)
  from expedientes e
  where es_cliente_de(e.cliente_id);
$$;

create or replace function portal_enviar_mensaje(p_expediente uuid, p_texto text)
returns uuid language plpgsql security invoker set search_path = despacho, public as $$
declare v_id uuid;
begin
  if not exists (select 1 from expedientes e where e.id = p_expediente and es_cliente_de(e.cliente_id)) then
    raise exception 'no_autorizado';
  end if;
  insert into mensajes (expediente_id, autor, texto) values (p_expediente, 'cliente', btrim(p_texto)) returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Seguridad a nivel de fila
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['expedientes','tareas','eventos','movimientos','accesos_documentos',
                           'mensajes','oportunidades','conversaciones_ia']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy abogado_todo on %I for all to authenticated using (es_abogado()) with check (es_abogado())', t);
  end loop;
end $$;

-- El cliente ve SOLO: sus expedientes, sus documentos compartidos, sus mensajes y sus cobros.
-- Nunca: tareas, notas internas, oportunidades, conversaciones IA ni datos de otros clientes.
create policy cliente_ve_expedientes on expedientes for select to authenticated using (es_cliente_de(cliente_id));
create policy cliente_ve_documentos on documentos for select to authenticated
  using (visible_cliente and exists (select 1 from expedientes e where e.id = expediente_id and es_cliente_de(e.cliente_id)));
create policy cliente_ve_mensajes on mensajes for select to authenticated
  using (exists (select 1 from expedientes e where e.id = expediente_id and es_cliente_de(e.cliente_id)));
create policy cliente_escribe_mensajes on mensajes for insert to authenticated
  with check (autor = 'cliente' and exists (select 1 from expedientes e where e.id = expediente_id and es_cliente_de(e.cliente_id)));
create policy cliente_ve_cobros on movimientos for select to authenticated
  using (tipo in ('honorario', 'provision_fondos')
         and exists (select 1 from expedientes e where e.id = expediente_id and es_cliente_de(e.cliente_id)));
create policy cliente_ve_eventos on eventos for select to authenticated
  using (tipo in ('audiencia', 'cita_cliente')
         and exists (select 1 from expedientes e where e.id = expediente_id and es_cliente_de(e.cliente_id)));
create policy cliente_se_ve on clientes for select to authenticated using (user_id = auth.uid());

-- El cliente no debe leer las notas internas aunque vea la fila del expediente.
revoke select on expedientes from authenticated;
grant select (id, numero, cliente_id, lead_id, materia_codigo, titulo, contraparte, organo, procedimiento, estado,
              responsable, honorarios_pactados, hoja_encargo_firmada, abierto_en, cerrado_en, creado_en, actualizado_en)
  on expedientes to authenticated;
-- El abogado lee las notas internas mediante esta función (comprueba es_abogado()).
create or replace function notas_expediente(p_expediente uuid)
returns text language sql stable security definer set search_path = despacho as $$
  select notas_internas from despacho.expedientes where id = p_expediente and despacho.es_abogado();
$$;

grant usage, select on sequence expediente_num_seq to authenticated, service_role;
grant all on expedientes, tareas, eventos, movimientos, accesos_documentos, mensajes, oportunidades, conversaciones_ia to service_role;
grant insert, update, delete on expedientes to authenticated;
grant select, insert, update, delete on tareas, eventos, movimientos, mensajes, oportunidades, conversaciones_ia to authenticated;
grant select, insert on accesos_documentos to authenticated;

revoke all on function abrir_expediente(uuid, text, numeric), panel_dashboard(), portal_resumen(),
  portal_enviar_mensaje(uuid, text), notas_expediente(uuid), es_cliente_de(uuid) from public, anon;
grant execute on function abrir_expediente(uuid, text, numeric), panel_dashboard(), portal_resumen(),
  portal_enviar_mensaje(uuid, text), notas_expediente(uuid), es_cliente_de(uuid) to authenticated, service_role;
