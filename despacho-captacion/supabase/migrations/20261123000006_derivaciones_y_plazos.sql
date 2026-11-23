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
