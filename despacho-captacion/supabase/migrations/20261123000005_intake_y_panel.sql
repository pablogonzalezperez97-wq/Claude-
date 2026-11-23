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
