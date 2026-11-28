-- INSTALACIÓN COMPLETA DEL DESPACHO (entorno de pruebas). Pegar entero en Supabase > SQL Editor > Run.
-- Crea solo el esquema 'despacho'; no modifica nada de 'public'. Si falla, no se aplica nada.
begin;

-- ===== migrations/20261123000001_esquema_inicial.sql =====
-- =====================================================================
-- Despacho de tarde · Esquema inicial (F1 + base de F2)
-- Datos, catálogo, agenda, conflictos, scoring, FAQ y trazabilidad.
-- Escrituras públicas: SOLO vía backend (service_role). El abogado accede
-- autenticado y figura en la tabla `abogados`. anon no lee datos personales.
-- =====================================================================

-- Todo el despacho vive en su propio esquema `despacho`, aislado de `public`.
create schema if not exists extensions;
create extension if not exists pg_trgm   with schema extensions;
create extension if not exists btree_gist with schema extensions;
create schema if not exists despacho;
set local search_path = despacho, extensions, public;

-- ---------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------
create type tipo_persona     as enum ('fisica', 'juridica');
create type nivel_materia    as enum ('nucleo', 'complementaria', 'derivar');
create type estado_lead      as enum ('nuevo', 'derivado', 'revision', 'apto', 'pagado', 'agendado', 'atendido', 'convertido', 'descartado');
create type estado_conflicto as enum ('pendiente', 'descartado', 'confirmado');
create type estado_cita      as enum ('reservada', 'confirmada', 'cancelada', 'reprogramada', 'realizada', 'no_presentado');
create type estado_pago      as enum ('pendiente', 'pagado', 'reembolsado', 'fallido');
create type modalidad_cita   as enum ('videollamada', 'presencial');

-- ---------------------------------------------------------------------
-- Utilidades
-- ---------------------------------------------------------------------

-- Normaliza nombres para el cruce de conflictos: minúsculas, sin tildes,
-- sin formas societarias ni signos. IMMUTABLE para poder indexarla.
create or replace function normalizar_nombre(t text)
returns text language sql immutable parallel safe set search_path = pg_catalog as $$
  select btrim(regexp_replace(
           regexp_replace(
             translate(lower(coalesce(t, '')), 'áàäâéèëêíìïîóòöôúùüûñç', 'aaaaeeeeiiiioooouuuunc'),
             '\m(s\.?\s?l\.?\s?u\.?|s\.?\s?l\.?|s\.?\s?a\.?\s?u\.?|s\.?\s?a\.?|s\.?\s?c\.?|s\.?\s?coop\.?|c\.?\s?b\.?)(\s|$)', ' ', 'g'),
           '[^a-z0-9 ]+', ' ', 'g'));
$$;

create or replace function normalizar_nif(t text)
returns text language sql immutable parallel safe set search_path = pg_catalog as $$
  select nullif(upper(regexp_replace(coalesce(t, ''), '[^A-Za-z0-9]', '', 'g')), '');
$$;

create or replace function tocar_actualizado()
returns trigger language plpgsql set search_path = pg_catalog as $$
begin new.actualizado_en := now(); return new; end $$;

-- ---------------------------------------------------------------------
-- Configuración (espejo de config/negocio.yaml)
-- ---------------------------------------------------------------------
create table parametros (
  clave text primary key,
  valor jsonb not null,
  descripcion text
);

create table disponibilidad (
  id serial primary key,
  dia_semana smallint not null check (dia_semana between 1 and 7), -- ISO: 1 = lunes
  inicio time not null,
  fin time not null,
  check (fin > inicio)
);

create table festivos (
  fecha date primary key,
  descripcion text
);

-- ---------------------------------------------------------------------
-- Catálogo de materias
-- ---------------------------------------------------------------------
create table materias (
  codigo text primary key,
  nombre text not null,
  area text not null,               -- mercantil, civil, tributario, administrativo, penal, familia...
  nivel nivel_materia not null,
  puntos smallint not null default 0,
  motivo_derivacion text,
  activa boolean not null default true
);

-- ---------------------------------------------------------------------
-- Usuarios internos
-- ---------------------------------------------------------------------
create table abogados (
  user_id uuid primary key,          -- auth.users.id
  nombre text not null,
  creado_en timestamptz not null default now()
);

create or replace function es_abogado()
returns boolean language sql stable security definer set search_path = despacho as $$
  select exists (select 1 from despacho.abogados where user_id = auth.uid());
$$;

-- ---------------------------------------------------------------------
-- Clientes, leads y contrapartes
-- ---------------------------------------------------------------------
create table clientes (
  id uuid primary key default gen_random_uuid(),
  tipo tipo_persona not null,
  nombre text not null,
  nif text,
  email text not null,
  telefono text,
  nombre_norm text generated always as (normalizar_nombre(nombre)) stored,
  nif_norm text generated always as (normalizar_nif(nif)) stored,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
create unique index clientes_nif_uq on clientes (nif_norm) where nif_norm is not null;
create index clientes_nombre_trgm on clientes using gin (nombre_norm gin_trgm_ops);
create trigger clientes_act before update on clientes for each row execute function tocar_actualizado();

create table leads (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id) on delete restrict,
  materia_codigo text references materias(codigo),
  descripcion text,                  -- relato del cliente (dato confidencial)
  es_empresa_o_autonomo boolean not null default false,
  fecha_limite date,                 -- plazo legal en curso, si lo hay
  cuantia_eur numeric(14,2),
  documentacion_aportada boolean not null default false,
  acepta_condiciones boolean not null default false,
  puntuacion smallint,
  alerta_plazo boolean not null default false,
  estado estado_lead not null default 'nuevo',
  origen text,                       -- web, asistente, recomendación...
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
create index leads_estado_idx on leads (estado);
create index leads_cliente_idx on leads (cliente_id);
create trigger leads_act before update on leads for each row execute function tocar_actualizado();

create table contrapartes (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references leads(id) on delete cascade,
  nombre text not null,
  nif text,
  nombre_norm text generated always as (normalizar_nombre(nombre)) stored,
  nif_norm text generated always as (normalizar_nif(nif)) stored,
  creado_en timestamptz not null default now()
);
create index contrapartes_lead_idx on contrapartes (lead_id);
create index contrapartes_nif_idx on contrapartes (nif_norm);
create index contrapartes_nombre_trgm on contrapartes using gin (nombre_norm gin_trgm_ops);

create table conflictos (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references leads(id) on delete cascade,
  tipo text not null,                -- 'contraparte_es_cliente' | 'cliente_fue_contraparte' | 'contraparte_repetida'
  criterio text not null,            -- 'nif' | 'nombre'
  similitud real,
  ref_lead_id uuid references leads(id) on delete set null,
  ref_cliente_id uuid references clientes(id) on delete set null,
  detalle text not null,
  estado estado_conflicto not null default 'pendiente',
  decidido_por uuid,
  decidido_en timestamptz,
  creado_en timestamptz not null default now()
);
create index conflictos_lead_idx on conflictos (lead_id);
create index conflictos_pend_idx on conflictos (estado) where estado = 'pendiente';

-- ---------------------------------------------------------------------
-- Pagos, citas y documentos
-- ---------------------------------------------------------------------
create table pagos (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references leads(id) on delete restrict,
  importe_eur numeric(10,2) not null check (importe_eur >= 0),
  estado estado_pago not null default 'pendiente',
  stripe_session_id text unique,
  stripe_payment_intent text unique,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
create trigger pagos_act before update on pagos for each row execute function tocar_actualizado();

create table citas (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references leads(id) on delete restrict,
  pago_id uuid references pagos(id),
  inicio timestamptz not null,
  fin timestamptz not null,
  modalidad modalidad_cita not null default 'videollamada',
  estado estado_cita not null default 'reservada',
  enlace_videollamada text,
  cal_booking_id text unique,
  reprogramaciones smallint not null default 0,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  check (fin > inicio),
  -- Imposible solapar dos citas activas (protege frente a dobles reservas).
  constraint citas_sin_solape exclude using gist (
    tstzrange(inicio, fin) with &&
  ) where (estado in ('reservada', 'confirmada'))
);
create index citas_inicio_idx on citas (inicio);
create trigger citas_act before update on citas for each row execute function tocar_actualizado();

create table documentos (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references leads(id) on delete cascade,
  ruta_storage text not null,        -- bucket privado 'documentos'
  nombre_original text not null,
  tipo_mime text,
  tamano_bytes bigint,
  subido_en timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Consentimientos (RGPD, condiciones, desistimiento, aviso IA)
-- ---------------------------------------------------------------------
create table consentimientos (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid references clientes(id) on delete cascade,
  lead_id uuid references leads(id) on delete cascade,
  tipo text not null,                -- 'privacidad' | 'condiciones' | 'inicio_antes_desistimiento' | 'comunicaciones'
  version_texto text not null,
  aceptado boolean not null,
  ip inet,
  user_agent text,
  creado_en timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- FAQ y trazabilidad del asistente IA
-- ---------------------------------------------------------------------
create table faq (
  id uuid primary key default gen_random_uuid(),
  area text not null,
  pregunta text not null,
  respuesta text not null,
  fuente_normativa text,
  validada boolean not null default false,
  validada_por uuid,
  validada_en timestamptz,
  version smallint not null default 1,
  revisar_en date,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
create trigger faq_act before update on faq for each row execute function tocar_actualizado();

create table interacciones_ia (
  id uuid primary key default gen_random_uuid(),
  sesion text not null,
  pregunta text not null,
  respuesta text not null,
  faq_ids uuid[] not null default '{}',
  derivada_a_cita boolean not null default false,
  motivo_derivacion text,
  modelo text,
  creado_en timestamptz not null default now()
);
create index interacciones_sesion_idx on interacciones_ia (sesion);

-- ---------------------------------------------------------------------
-- Lógica: días hábiles, conflictos, scoring y triaje
-- ---------------------------------------------------------------------

-- Días hábiles (lun-vie, sin festivos) entre hoy (excluido) y la fecha (incluida).
create or replace function dias_habiles_hasta(p_fecha date, p_desde date default current_date)
returns integer language sql stable set search_path = despacho, pg_catalog as $$
  select count(*)::int
  from generate_series(p_desde + 1, p_fecha, interval '1 day') d
  where extract(isodow from d) < 6
    and not exists (select 1 from festivos f where f.fecha = d::date);
$$;

create or replace function detectar_conflictos(p_lead uuid)
returns integer language plpgsql security definer set search_path = despacho, extensions, public as $$
declare
  v_umbral real := coalesce((select (valor->>0)::real from parametros where clave = 'conflictos.umbral_similitud'), 0.55);
  v_cliente clientes%rowtype;
  v_n integer;
begin
  select c.* into v_cliente from leads l join clientes c on c.id = l.cliente_id where l.id = p_lead;
  if not found then raise exception 'Lead % no existe', p_lead; end if;

  delete from conflictos where lead_id = p_lead and estado = 'pendiente';

  -- 1) La contraparte de este asunto es (o se parece a) un cliente nuestro.
  insert into conflictos (lead_id, tipo, criterio, similitud, ref_cliente_id, detalle)
  select p_lead, 'contraparte_es_cliente',
         case when cp.nif_norm is not null and cp.nif_norm = c.nif_norm then 'nif' else 'nombre' end,
         similarity(cp.nombre_norm, c.nombre_norm), c.id,
         format('La contraparte "%s" coincide con el cliente "%s"', cp.nombre, c.nombre)
  from contrapartes cp
  join clientes c on c.id <> v_cliente.id
   and ((cp.nif_norm is not null and cp.nif_norm = c.nif_norm)
        or similarity(cp.nombre_norm, c.nombre_norm) >= v_umbral)
  where cp.lead_id = p_lead;

  -- 2) Nuestro cliente potencial fue contraparte en otro asunto.
  insert into conflictos (lead_id, tipo, criterio, similitud, ref_lead_id, detalle)
  select p_lead, 'cliente_fue_contraparte',
         case when v_cliente.nif_norm is not null and cp.nif_norm = v_cliente.nif_norm then 'nif' else 'nombre' end,
         similarity(cp.nombre_norm, v_cliente.nombre_norm), cp.lead_id,
         format('El cliente "%s" figura como contraparte ("%s") en otro asunto', v_cliente.nombre, cp.nombre)
  from contrapartes cp
  where cp.lead_id <> p_lead
    and ((v_cliente.nif_norm is not null and cp.nif_norm = v_cliente.nif_norm)
         or similarity(cp.nombre_norm, v_cliente.nombre_norm) >= v_umbral);

  -- 3) La misma contraparte aparece en asuntos de otros clientes (posible interés cruzado).
  insert into conflictos (lead_id, tipo, criterio, similitud, ref_lead_id, detalle)
  select p_lead, 'contraparte_repetida',
         case when a.nif_norm is not null and a.nif_norm = b.nif_norm then 'nif' else 'nombre' end,
         similarity(a.nombre_norm, b.nombre_norm), b.lead_id,
         format('La contraparte "%s" ya aparece en otro asunto', a.nombre)
  from contrapartes a
  join contrapartes b on b.lead_id <> p_lead
   and ((a.nif_norm is not null and a.nif_norm = b.nif_norm)
        or similarity(a.nombre_norm, b.nombre_norm) >= v_umbral)
  join leads lb on lb.id = b.lead_id and lb.cliente_id <> v_cliente.id
  where a.lead_id = p_lead;

  select count(*) into v_n from conflictos where lead_id = p_lead and estado = 'pendiente';
  return v_n;
end $$;

create or replace function calcular_puntuacion(p_lead uuid)
returns smallint language sql stable set search_path = despacho, pg_catalog as $$
  select (
      coalesce(m.puntos, 0)
    + case when l.fecha_limite is not null and l.fecha_limite >= current_date then 20 else 0 end
    + case when l.cuantia_eur >= coalesce((select (valor->>0)::numeric from parametros where clave = 'scoring.umbral_cuantia_eur'), 6000) then 15 else 0 end
    + case when l.documentacion_aportada then 15 else 0 end
    + case when l.es_empresa_o_autonomo then 10 else 0 end
    + case when l.acepta_condiciones then 10 else 0 end
  )::smallint
  from leads l left join materias m on m.codigo = l.materia_codigo
  where l.id = p_lead;
$$;

-- Triaje completo: derivación → conflictos → puntuación → estado.
create or replace function evaluar_lead(p_lead uuid)
returns table (estado estado_lead, puntuacion smallint, conflictos_pendientes integer, alerta_plazo boolean)
language plpgsql security definer set search_path = despacho, extensions, public as $$
declare
  v_nivel nivel_materia;
  v_lim date;
  v_punt smallint;
  v_conf integer;
  v_alerta boolean := false;
  v_estado estado_lead;
  v_umbral_directo int := coalesce((select (valor->>0)::int from parametros where clave = 'scoring.umbral_agenda_directa'), 70);
  v_umbral_revision int := coalesce((select (valor->>0)::int from parametros where clave = 'scoring.umbral_revision'), 40);
  v_dias_alerta int := coalesce((select (valor->>0)::int from parametros where clave = 'scoring.alerta_plazo_dias_habiles'), 5);
begin
  select m.nivel, l.fecha_limite into v_nivel, v_lim
  from leads l left join materias m on m.codigo = l.materia_codigo where l.id = p_lead;

  if v_lim is not null and v_lim >= current_date then
    v_alerta := dias_habiles_hasta(v_lim) <= v_dias_alerta;
  end if;

  if v_nivel = 'derivar' then
    v_estado := 'derivado'; v_punt := 0; v_conf := 0;
  else
    v_conf := detectar_conflictos(p_lead);
    v_punt := calcular_puntuacion(p_lead);
    v_estado := case
      when v_conf > 0 or v_nivel is null then 'revision'   -- conflicto o materia sin clasificar: decide el abogado
      when v_punt >= v_umbral_directo then 'apto'
      when v_punt >= v_umbral_revision then 'revision'
      else 'descartado'
    end;
  end if;

  update leads set puntuacion = v_punt, alerta_plazo = v_alerta, estado = v_estado where id = p_lead;
  return query select v_estado, v_punt, v_conf, v_alerta;
end $$;

-- Las funciones con privilegios elevados solo las invoca el backend o el abogado.
revoke all on function detectar_conflictos(uuid) from public;
revoke all on function evaluar_lead(uuid) from public;
grant execute on function detectar_conflictos(uuid) to service_role, authenticated;
grant execute on function evaluar_lead(uuid) to service_role, authenticated;

-- ---------------------------------------------------------------------
-- Seguridad a nivel de fila (RLS)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['parametros','disponibilidad','festivos','materias','abogados','clientes','leads',
                           'contrapartes','conflictos','pagos','citas','documentos','consentimientos',
                           'faq','interacciones_ia']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy abogado_todo on %I for all to authenticated using (es_abogado()) with check (es_abogado())', t);
  end loop;
end $$;

-- Permisos de esquema (Supabase solo los concede por defecto en `public`).
grant usage on schema despacho to anon, authenticated, service_role;
grant all on all tables in schema despacho to service_role;
grant all on all sequences in schema despacho to service_role;
grant select, insert, update, delete on all tables in schema despacho to authenticated;  -- RLS filtra
grant usage on all sequences in schema despacho to authenticated;
grant select on despacho.materias, despacho.disponibilidad, despacho.festivos, despacho.faq to anon;  -- RLS filtra

-- Lectura pública mínima, sin datos personales: catálogo, franjas, festivos y FAQ validadas.
create policy publico_lee_materias       on materias       for select to anon using (activa);
create policy publico_lee_disponibilidad on disponibilidad for select to anon using (true);
create policy publico_lee_festivos       on festivos       for select to anon using (true);
create policy publico_lee_faq            on faq            for select to anon using (validada);

-- ===== migrations/20261123000002_datos_iniciales.sql =====
-- =====================================================================
-- Datos iniciales: parámetros, franjas y catálogo de materias
-- (espejo de config/negocio.yaml, validado por el abogado el 23-11-2026)
-- =====================================================================

set local search_path = despacho;

insert into parametros (clave, valor, descripcion) values
  ('consulta.duracion_min',            '[30]',   'Duración de la consulta inicial'),
  ('consulta.margen_min',              '[15]',   'Margen entre citas'),
  ('consulta.precio_eur',              '[50]',   'Precio de la consulta inicial (no descontable del asunto)'),
  ('consulta.descontable',             '[false]','El resto del asunto se presupuesta aparte'),
  ('consulta.modalidad',               '["videollamada"]', 'Modalidad por defecto'),
  ('capacidad.tope_citas_semana',      '[5]',    'Máximo de consultas por semana'),
  ('capacidad.antelacion_minima_h',    '[12]',   'Antelación mínima para reservar'),
  ('capacidad.horizonte_dias',         '[21]',   'Hasta cuántos días vista se puede reservar'),
  ('cancelacion.reembolso_antes_h',    '[24]',   'Reembolso íntegro si se cancela con esta antelación'),
  ('cancelacion.reprogramaciones',     '[1]',    'Reprogramaciones gratuitas'),
  ('scoring.umbral_agenda_directa',    '[70]',   'Puntuación para agenda directa'),
  ('scoring.umbral_revision',          '[40]',   'Puntuación mínima para revisión del abogado'),
  ('scoring.umbral_cuantia_eur',       '[6000]', 'Cuantía a partir de la cual suma puntos'),
  ('scoring.alerta_plazo_dias_habiles','[5]',    'Alerta si el plazo vence en estos días hábiles o menos'),
  ('conflictos.umbral_similitud',      '[0.55]', 'Similitud mínima de nombres (0-1) para marcar posible conflicto');

insert into disponibilidad (dia_semana, inicio, fin) values
  (1, '18:00', '21:00'),  -- lunes
  (2, '19:15', '21:15'),  -- martes
  (3, '19:15', '21:15'),  -- miércoles
  (4, '18:00', '21:00');  -- jueves

insert into materias (codigo, nombre, area, nivel, puntos, motivo_derivacion) values
  -- Núcleo mercantil
  ('mer_constitucion',     'Constitución de sociedades',                          'mercantil', 'nucleo', 30, null),
  ('mer_modificaciones',   'Modificaciones estatutarias, ampliaciones y reducciones de capital', 'mercantil', 'nucleo', 30, null),
  ('mer_pactos_socios',    'Pactos de socios y conflictos societarios',           'mercantil', 'nucleo', 30, null),
  ('mer_juntas',           'Juntas, actas y acuerdos sociales',                   'mercantil', 'nucleo', 30, null),
  ('mer_contratos',        'Contratos mercantiles (distribución, agencia, servicios, NDA, compraventa)', 'mercantil', 'nucleo', 30, null),
  ('mer_deudas',           'Reclamación de deudas comerciales',                   'mercantil', 'nucleo', 30, null),
  ('mer_administradores',  'Responsabilidad de administradores',                  'mercantil', 'nucleo', 30, null),
  ('mer_compraventa_emp',  'Compraventa de participaciones o de negocio',         'mercantil', 'nucleo', 30, null),
  -- Complementario
  ('civ_contratos',        'Contratos civiles',                                   'civil', 'complementaria', 20, null),
  ('civ_reclamaciones',    'Reclamaciones de cantidad',                           'civil', 'complementaria', 20, null),
  ('civ_arrendamientos',   'Arrendamientos',                                      'civil', 'complementaria', 20, null),
  ('civ_herencias',        'Herencias sencillas',                                 'civil', 'complementaria', 20, null),
  ('tri_requerimientos',   'Requerimientos y comprobaciones de la AEAT',          'tributario', 'complementaria', 20, null),
  ('tri_sanciones',        'Sanciones tributarias y recursos',                    'tributario', 'complementaria', 20, null),
  ('adm_sanciones',        'Multas y sanciones administrativas',                  'administrativo', 'complementaria', 20, null),
  -- Derivación (urgencia incompatible con atención de tarde)
  ('der_penal_detenido',   'Penal con persona detenida o asistencia en guardia',  'penal', 'derivar', 0, 'Requiere asistencia inmediata'),
  ('der_violencia_genero', 'Violencia de género',                                 'penal', 'derivar', 0, 'Requiere atención inmediata y especializada'),
  ('der_familia_urgente',  'Medidas urgentes de familia',                         'familia', 'derivar', 0, 'Requiere actuación inmediata'),
  ('der_desahucio_inminente', 'Desahucio con lanzamiento inminente',              'civil', 'derivar', 0, 'Plazo incompatible con la franja de atención');

-- ===== migrations/20261123000003_festivos_la_rioja.sql =====
-- =====================================================================
-- Festivos laborales de La Rioja (no cuentan como días hábiles ni se agendan)
-- 2026: Acuerdo del Gobierno de La Rioja, BOR nº 89 de 12-05-2025 (12 fiestas).
-- 2027: BOR de 08-05-2026. Las 8 primeras están confirmadas; las 4 marcadas
--       "(verificar)" se deducen del calendario y hay que contrastarlas con el BOR.
-- Festivos LOCALES: pendientes de saber el municipio del despacho.
-- =====================================================================

set local search_path = despacho;

insert into festivos (fecha, descripcion) values
  ('2026-01-01', 'Año Nuevo'),
  ('2026-01-06', 'Epifanía del Señor'),
  ('2026-04-02', 'Jueves Santo'),
  ('2026-04-03', 'Viernes Santo'),
  ('2026-04-06', 'Lunes de Pascua'),
  ('2026-05-01', 'Fiesta del Trabajo'),
  ('2026-06-09', 'Día de La Rioja'),
  ('2026-08-15', 'Asunción de la Virgen'),
  ('2026-10-12', 'Fiesta Nacional de España'),
  ('2026-12-07', 'Lunes siguiente a la Constitución'),
  ('2026-12-08', 'Inmaculada Concepción'),
  ('2026-12-25', 'Natividad del Señor'),

  ('2027-01-01', 'Año Nuevo'),
  ('2027-01-06', 'Epifanía del Señor'),
  ('2027-03-25', 'Jueves Santo'),
  ('2027-03-26', 'Viernes Santo'),
  ('2027-03-29', 'Lunes de Pascua'),
  ('2027-05-01', 'Fiesta del Trabajo'),
  ('2027-06-09', 'Día de La Rioja'),
  ('2027-10-12', 'Fiesta Nacional de España'),
  ('2027-11-01', 'Todos los Santos (verificar)'),
  ('2027-12-06', 'Día de la Constitución (verificar)'),
  ('2027-12-08', 'Inmaculada Concepción (verificar)'),
  ('2027-12-25', 'Natividad del Señor (verificar)')
on conflict (fecha) do update set descripcion = excluded.descripcion;

-- ===== migrations/20261123000004_festivos_logrono.sql =====
-- =====================================================================
-- Fiestas locales de Logroño (municipio del despacho)
-- 2026: San Bernabé (11-jun) y San Mateo (21-sep).
-- 2027: mismas fiestas por tradición; el Ayuntamiento aún no las ha publicado (verificar).
-- =====================================================================

set local search_path = despacho;

insert into festivos (fecha, descripcion) values
  ('2026-06-11', 'San Bernabé (Logroño)'),
  ('2026-09-21', 'San Mateo (Logroño)'),
  ('2027-06-11', 'San Bernabé (Logroño) (verificar)'),
  ('2027-09-21', 'San Mateo (Logroño) (verificar)')
on conflict (fecha) do update set descripcion = excluded.descripcion;

-- ===== migrations/20261123000005_intake_y_panel.sql =====
-- =====================================================================
-- Intake (formulario de consulta) y panel de revisión del abogado
-- - registrar_lead(): alta atómica desde el formulario. Solo service_role.
-- - panel_pendientes(), decidir_lead(), decidir_conflicto(): uso del abogado,
--   SECURITY INVOKER → se aplican las políticas RLS.
-- =====================================================================

set local search_path = despacho, extensions, public;

alter table leads
  add column revisado_por uuid,
  add column revisado_en timestamptz,
  add column nota_revision text,
  add column alerta_notificada_en timestamptz,
  add column email_contacto text,        -- email con el que se hizo ESTA solicitud (puede diferir del cliente ya registrado)
  add column telefono_contacto text;

-- ---------------------------------------------------------------------
-- Alta desde el formulario
-- ---------------------------------------------------------------------
create or replace function registrar_lead(p jsonb, p_ip inet default null, p_ua text default null)
returns jsonb
language plpgsql security definer set search_path = despacho, extensions, public as $$
declare
  v_tipo      tipo_persona := (p->>'tipo')::tipo_persona;
  v_nombre    text := btrim(p->>'nombre');
  v_email     text := lower(btrim(p->>'email'));
  v_nif       text := normalizar_nif(p->>'nif');
  v_materia   materias%rowtype;
  v_cliente   uuid;
  v_lead      uuid;
  v_res       record;
  v_cp        jsonb;
  v_version   text := coalesce(p->>'version_textos', 'v1');
  v_recientes int;
begin
  -- Validaciones de servidor (la web valida también, pero no se confía en ella).
  if v_nombre is null or length(v_nombre) < 2 or length(v_nombre) > 200 then raise exception 'nombre_invalido'; end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'email_invalido'; end if;
  if v_tipo = 'juridica' and v_nif is null then raise exception 'nif_obligatorio_juridica'; end if;
  if coalesce((p->>'acepta_privacidad')::boolean, false) is not true then raise exception 'falta_privacidad'; end if;
  if coalesce((p->>'acepta_condiciones')::boolean, false) is not true then raise exception 'faltan_condiciones'; end if;
  if length(coalesce(p->>'descripcion', '')) < 20 or length(p->>'descripcion') > 4000 then raise exception 'descripcion_invalida'; end if;
  if (p->>'fecha_limite') is not null and (p->>'fecha_limite')::date < current_date then raise exception 'fecha_limite_pasada'; end if;
  if (p->>'cuantia_eur') is not null and (p->>'cuantia_eur')::numeric < 0 then raise exception 'cuantia_invalida'; end if;
  if jsonb_array_length(coalesce(p->'contrapartes', '[]')) > 5 then raise exception 'demasiadas_contrapartes'; end if;

  select * into v_materia from materias where codigo = p->>'materia' and activa;
  if not found then raise exception 'materia_invalida'; end if;

  -- Cliente: si el NIF ya existe se vincula SIN sobrescribir datos (la entrada no es de confianza).
  if v_nif is not null then
    select id into v_cliente from clientes where nif_norm = v_nif;
  end if;
  if v_cliente is null then
    insert into clientes (tipo, nombre, nif, email, telefono)
    values (v_tipo, v_nombre, v_nif, v_email, nullif(btrim(p->>'telefono'), ''))
    returning id into v_cliente;
  end if;

  -- Antiabuso: máximo 3 solicitudes en 24 h por email de contacto o por cliente.
  select count(*) into v_recientes from leads l
  where l.creado_en > now() - interval '24 hours'
    and (l.email_contacto = v_email or l.cliente_id = v_cliente);
  if v_recientes >= 3 then raise exception 'limite_solicitudes'; end if;

  insert into leads (cliente_id, materia_codigo, descripcion, es_empresa_o_autonomo, fecha_limite,
                     cuantia_eur, documentacion_aportada, acepta_condiciones, origen,
                     email_contacto, telefono_contacto)
  values (v_cliente, v_materia.codigo, p->>'descripcion',
          v_tipo = 'juridica' or coalesce((p->>'es_autonomo')::boolean, false),
          (p->>'fecha_limite')::date, (p->>'cuantia_eur')::numeric,
          coalesce((p->>'documentacion_disponible')::boolean, false), true,
          coalesce(nullif(p->>'origen', ''), 'web'),
          v_email, nullif(btrim(p->>'telefono'), ''))
  returning id into v_lead;

  for v_cp in select * from jsonb_array_elements(coalesce(p->'contrapartes', '[]')) loop
    if length(btrim(coalesce(v_cp->>'nombre', ''))) >= 2 then
      insert into contrapartes (lead_id, nombre, nif) values (v_lead, btrim(v_cp->>'nombre'), v_cp->>'nif');
    end if;
  end loop;

  insert into consentimientos (cliente_id, lead_id, tipo, version_texto, aceptado, ip, user_agent) values
    (v_cliente, v_lead, 'privacidad',  v_version, true, p_ip, p_ua),
    (v_cliente, v_lead, 'condiciones', v_version, true, p_ip, p_ua),
    (v_cliente, v_lead, 'comunicaciones', v_version, coalesce((p->>'acepta_comunicaciones')::boolean, false), p_ip, p_ua);

  select * into v_res from evaluar_lead(v_lead);

  -- La respuesta al público NUNCA revela conflictos ni puntuación (secreto profesional).
  return jsonb_build_object(
    'lead_id', v_lead,
    'resultado', case v_res.estado
                   when 'apto' then 'reservar'
                   when 'derivado' then 'derivar'
                   when 'revision' then 'en_revision'
                   else 'no_encaja' end,
    'motivo_derivacion', case when v_res.estado = 'derivado' then v_materia.motivo_derivacion end
  );
end $$;

revoke all on function registrar_lead(jsonb, inet, text) from public, anon, authenticated;
grant execute on function registrar_lead(jsonb, inet, text) to service_role;

-- ---------------------------------------------------------------------
-- Panel del abogado (RLS aplica: solo devuelve datos si es_abogado())
-- ---------------------------------------------------------------------
create or replace function panel_pendientes()
returns jsonb language sql stable security invoker set search_path = despacho, public as $$
  select coalesce(jsonb_agg(x order by (x->>'alerta_plazo')::boolean desc, x->>'creado_en'), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', l.id, 'estado', l.estado, 'puntuacion', l.puntuacion, 'alerta_plazo', l.alerta_plazo,
      'fecha_limite', l.fecha_limite,
      'dias_habiles', case when l.fecha_limite is not null then dias_habiles_hasta(l.fecha_limite) end,
      'cuantia_eur', l.cuantia_eur, 'descripcion', l.descripcion, 'creado_en', l.creado_en,
      'documentacion_aportada', l.documentacion_aportada,
      'materia', jsonb_build_object('codigo', m.codigo, 'nombre', m.nombre, 'area', m.area, 'nivel', m.nivel),
      'cliente', jsonb_build_object('nombre', c.nombre, 'tipo', c.tipo, 'nif', c.nif, 'email', c.email, 'telefono', c.telefono),
      'contacto', jsonb_build_object('email', l.email_contacto, 'telefono', l.telefono_contacto),
      'contrapartes', coalesce((select jsonb_agg(jsonb_build_object('nombre', cp.nombre, 'nif', cp.nif))
                                from contrapartes cp where cp.lead_id = l.id), '[]'),
      'conflictos', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'tipo', k.tipo, 'criterio', k.criterio,
                                       'similitud', round(k.similitud::numeric, 2), 'detalle', k.detalle, 'estado', k.estado))
                              from conflictos k where k.lead_id = l.id), '[]')
    ) x
    from leads l
    join clientes c on c.id = l.cliente_id
    left join materias m on m.codigo = l.materia_codigo
    where l.estado in ('revision', 'apto')
  ) s;
$$;

create or replace function decidir_conflicto(p_conflicto uuid, p_estado estado_conflicto, p_nota text default null)
returns void language plpgsql security invoker set search_path = despacho, public as $$
declare v_lead uuid;
begin
  if not es_abogado() then raise exception 'no_autorizado'; end if;
  if p_estado = 'pendiente' then raise exception 'estado_no_valido'; end if;

  update conflictos set estado = p_estado, decidido_por = auth.uid(), decidido_en = now()
  where id = p_conflicto returning lead_id into v_lead;
  if v_lead is null then raise exception 'conflicto_no_encontrado'; end if;

  -- Un conflicto confirmado impide aceptar el asunto.
  if p_estado = 'confirmado' then
    update leads set estado = 'descartado', revisado_por = auth.uid(), revisado_en = now(),
                     nota_revision = coalesce(p_nota, 'Conflicto de intereses confirmado')
    where id = v_lead;
  end if;
end $$;

create or replace function decidir_lead(p_lead uuid, p_decision text, p_nota text default null)
returns estado_lead language plpgsql security invoker set search_path = despacho, public as $$
declare v_estado estado_lead;
begin
  if not es_abogado() then raise exception 'no_autorizado'; end if;

  if p_decision = 'aceptar' then
    if exists (select 1 from conflictos where lead_id = p_lead and estado <> 'descartado') then
      raise exception 'conflictos_sin_resolver';
    end if;
    v_estado := 'apto';
  elsif p_decision = 'rechazar' then v_estado := 'descartado';
  elsif p_decision = 'derivar'  then v_estado := 'derivado';
  else raise exception 'decision_no_valida';
  end if;

  update leads set estado = v_estado, revisado_por = auth.uid(), revisado_en = now(), nota_revision = p_nota
  where id = p_lead and estado in ('revision', 'apto');
  if not found then raise exception 'lead_no_revisable'; end if;
  return v_estado;
end $$;

revoke all on function panel_pendientes() from public, anon;
revoke all on function decidir_conflicto(uuid, estado_conflicto, text) from public, anon;
revoke all on function decidir_lead(uuid, text, text) from public, anon;
grant execute on function panel_pendientes() to authenticated, service_role;
grant execute on function decidir_conflicto(uuid, estado_conflicto, text) to authenticated, service_role;
grant execute on function decidir_lead(uuid, text, text) to authenticated, service_role;

-- ===== migrations/20261123000006_derivaciones_y_plazos.sql =====
-- =====================================================================
-- Derivaciones manuales agrupadas por área + plazo de respuesta (2 días laborables)
-- Criterios del abogado (23-11-2026):
--   · Las derivaciones NO se remiten automáticamente: el abogado las reenvía a mano,
--     agrupadas por área para poder enviar varios casos al mismo compañero.
--   · Respuesta a solicitudes en revisión: máximo 2 días laborables.
-- =====================================================================

set local search_path = despacho, extensions, public;

alter table leads
  add column reenviado_a text,
  add column reenviado_en timestamptz;

insert into parametros (clave, valor, descripcion) values
  ('revision.plazo_respuesta_dias_habiles', '[2]', 'Plazo máximo para responder a solicitudes en revisión'),
  ('consulta.iva_incluido', '[true]', 'El precio de la consulta (50 €) incluye IVA: base 41,32 € + 8,68 € de IVA al 21 %')
on conflict (clave) do update set valor = excluded.valor, descripcion = excluded.descripcion;

-- Suma n días hábiles (lun-vie, sin festivos) a una fecha.
create or replace function sumar_dias_habiles(p_desde date, p_n int)
returns date language sql stable set search_path = despacho, pg_catalog as $$
  select d::date from generate_series(p_desde + 1, p_desde + 60, interval '1 day') d
  where extract(isodow from d) < 6 and not exists (select 1 from festivos f where f.fecha = d::date)
  order by d offset greatest(p_n, 1) - 1 limit 1;
$$;

-- Bandeja: añade la fecha límite de respuesta a cada solicitud pendiente.
create or replace function panel_pendientes()
returns jsonb language sql stable security invoker set search_path = despacho, public as $$
  select coalesce(jsonb_agg(x order by (x->>'alerta_plazo')::boolean desc, x->>'responder_antes', x->>'creado_en'), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', l.id, 'estado', l.estado, 'puntuacion', l.puntuacion, 'alerta_plazo', l.alerta_plazo,
      'fecha_limite', l.fecha_limite,
      'dias_habiles', case when l.fecha_limite is not null then dias_habiles_hasta(l.fecha_limite) end,
      'responder_antes', sumar_dias_habiles((l.creado_en at time zone 'Europe/Madrid')::date,
                           coalesce((select (valor->>0)::int from parametros where clave = 'revision.plazo_respuesta_dias_habiles'), 2)),
      'cuantia_eur', l.cuantia_eur, 'descripcion', l.descripcion, 'creado_en', l.creado_en,
      'documentacion_aportada', l.documentacion_aportada,
      'materia', jsonb_build_object('codigo', m.codigo, 'nombre', m.nombre, 'area', m.area, 'nivel', m.nivel),
      'cliente', jsonb_build_object('nombre', c.nombre, 'tipo', c.tipo, 'nif', c.nif, 'email', c.email, 'telefono', c.telefono),
      'contacto', jsonb_build_object('email', l.email_contacto, 'telefono', l.telefono_contacto),
      'contrapartes', coalesce((select jsonb_agg(jsonb_build_object('nombre', cp.nombre, 'nif', cp.nif))
                                from contrapartes cp where cp.lead_id = l.id), '[]'),
      'conflictos', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'tipo', k.tipo, 'criterio', k.criterio,
                                       'similitud', round(k.similitud::numeric, 2), 'detalle', k.detalle, 'estado', k.estado))
                              from conflictos k where k.lead_id = l.id), '[]')
    ) x
    from leads l
    join clientes c on c.id = l.cliente_id
    left join materias m on m.codigo = l.materia_codigo
    where l.estado in ('revision', 'apto')
  ) s;
$$;

-- Derivaciones pendientes de reenviar, agrupadas por área (penal, familia, civil...).
create or replace function panel_derivaciones()
returns jsonb language sql stable security invoker set search_path = despacho, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('area', area, 'casos', casos) order by area), '[]'::jsonb)
  from (
    select coalesce(m.area, 'sin clasificar') area,
           jsonb_agg(jsonb_build_object(
             'id', l.id, 'creado_en', l.creado_en, 'materia', m.nombre, 'motivo', m.motivo_derivacion,
             'cliente', c.nombre, 'email', l.email_contacto, 'telefono', l.telefono_contacto,
             'descripcion', l.descripcion, 'fecha_limite', l.fecha_limite,
             'contrapartes', coalesce((select jsonb_agg(cp.nombre) from contrapartes cp where cp.lead_id = l.id), '[]')
           ) order by l.creado_en) casos
    from leads l
    join clientes c on c.id = l.cliente_id
    left join materias m on m.codigo = l.materia_codigo
    where l.estado = 'derivado' and l.reenviado_en is null
    group by 1
  ) g;
$$;

create or replace function marcar_reenviado(p_leads uuid[], p_destinatario text, p_nota text default null)
returns integer language plpgsql security invoker set search_path = despacho, public as $$
declare v_n integer;
begin
  if not es_abogado() then raise exception 'no_autorizado'; end if;
  if length(btrim(coalesce(p_destinatario, ''))) < 2 then raise exception 'falta_destinatario'; end if;
  update leads set reenviado_a = btrim(p_destinatario), reenviado_en = now(),
                   revisado_por = auth.uid(), revisado_en = now(),
                   nota_revision = coalesce(p_nota, nota_revision)
  where id = any(p_leads) and estado = 'derivado' and reenviado_en is null;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke all on function panel_derivaciones() from public, anon;
revoke all on function marcar_reenviado(uuid[], text, text) from public, anon;
grant execute on function panel_derivaciones() to authenticated, service_role;
grant execute on function marcar_reenviado(uuid[], text, text) to authenticated, service_role;

-- ===== migrations/20261128000007_gestion_y_portal.sql =====
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

commit;
