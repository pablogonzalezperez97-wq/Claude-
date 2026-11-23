-- =====================================================================
-- Despacho de tarde · Esquema inicial (F1 + base de F2)
-- Datos, catálogo, agenda, conflictos, scoring, FAQ y trazabilidad.
-- Escrituras públicas: SOLO vía backend (service_role). El abogado accede
-- autenticado y figura en la tabla `abogados`. anon no lee datos personales.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pg_trgm   with schema extensions;
create extension if not exists btree_gist with schema extensions;

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
returns text language sql immutable parallel safe as $$
  select btrim(regexp_replace(
           regexp_replace(
             translate(lower(coalesce(t, '')), 'áàäâéèëêíìïîóòöôúùüûñç', 'aaaaeeeeiiiioooouuuunc'),
             '\m(s\.?\s?l\.?\s?u\.?|s\.?\s?l\.?|s\.?\s?a\.?\s?u\.?|s\.?\s?a\.?|s\.?\s?c\.?|s\.?\s?coop\.?|c\.?\s?b\.?)(\s|$)', ' ', 'g'),
           '[^a-z0-9 ]+', ' ', 'g'));
$$;

create or replace function normalizar_nif(t text)
returns text language sql immutable parallel safe as $$
  select nullif(upper(regexp_replace(coalesce(t, ''), '[^A-Za-z0-9]', '', 'g')), '');
$$;

create or replace function tocar_actualizado()
returns trigger language plpgsql as $$
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
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.abogados where user_id = auth.uid());
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
create index clientes_nombre_trgm on clientes using gin (nombre_norm extensions.gin_trgm_ops);
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
create index contrapartes_nombre_trgm on contrapartes using gin (nombre_norm extensions.gin_trgm_ops);

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
returns integer language sql stable as $$
  select count(*)::int
  from generate_series(p_desde + 1, p_fecha, interval '1 day') d
  where extract(isodow from d) < 6
    and not exists (select 1 from festivos f where f.fecha = d::date);
$$;

create or replace function detectar_conflictos(p_lead uuid)
returns integer language plpgsql security definer set search_path = public, extensions as $$
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
returns smallint language sql stable as $$
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
language plpgsql security definer set search_path = public, extensions as $$
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

-- Lectura pública mínima, sin datos personales: catálogo, franjas, festivos y FAQ validadas.
create policy publico_lee_materias       on materias       for select to anon using (activa);
create policy publico_lee_disponibilidad on disponibilidad for select to anon using (true);
create policy publico_lee_festivos       on festivos       for select to anon using (true);
create policy publico_lee_faq            on faq            for select to anon using (validada);
