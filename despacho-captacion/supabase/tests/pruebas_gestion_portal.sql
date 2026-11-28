-- Pruebas de gestión (expedientes, agenda, finanzas) y del aislamiento del portal del cliente.
-- psql -1 -v ON_ERROR_STOP=1 -f pruebas_gestion_portal.sql   (todo se revierte)
set local search_path = despacho, extensions, public;

do $$
declare
  v_abog uuid := '99999999-9999-9999-9999-999999999999';
  v_u1 uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
  v_u2 uuid := 'aaaaaaaa-0000-0000-0000-000000000002';
  v_c1 uuid; v_c2 uuid; v_l1 uuid; v_l2 uuid; v_e1 uuid; v_e2 uuid; v_cita uuid; d jsonb; p jsonb; v_err text; v_n int;
begin
  insert into abogados values (v_abog, 'Abogado') on conflict do nothing;
  insert into clientes (tipo, nombre, email, user_id) values ('fisica', 'Cliente Uno', 'uno@x.test', v_u1) returning id into v_c1;
  insert into clientes (tipo, nombre, email, user_id) values ('fisica', 'Cliente Dos', 'dos@x.test', v_u2) returning id into v_c2;
  insert into leads (cliente_id, materia_codigo, estado) values (v_c1, 'mer_pactos_socios', 'apto') returning id into v_l1;
  insert into leads (cliente_id, materia_codigo, estado) values (v_c2, 'mer_deudas', 'apto') returning id into v_l2;
  insert into contrapartes (lead_id, nombre) values (v_l1, 'Socio Saliente');
  insert into oportunidades (lead_id, materia_codigo, necesidad, evidencia, confianza)
    values (v_l1, 'mer_juntas', 'Las juntas no se documentan en acta', '"nunca hacemos actas de las reuniones"', 0.8);

  -- Abogado: abre expedientes, crea tareas, eventos y movimientos
  perform set_config('request.jwt.claim.sub', v_abog::text, true);
  set local role authenticated;
  v_e1 := abrir_expediente(v_l1, 'Cliente Uno · pacto de socios', 1500);
  v_e2 := abrir_expediente(v_l2, 'Cliente Dos · reclamación', 900);
  assert (select numero from expedientes where id = v_e1) ~ '^\d{4}/\d{4}$', 'numeración';
  assert (select estado from leads where id = v_l1) = 'convertido', 'lead convertido';
  assert (select expediente_id from oportunidades where lead_id = v_l1) = v_e1, 'oportunidad enlazada';
  assert (select contraparte from expedientes where id = v_e1) = 'Socio Saliente', 'contraparte copiada';
  update expedientes set notas_internas = 'Cliente difícil, cobrar por adelantado' where id = v_e1;

  insert into tareas (expediente_id, titulo, vence_en) values (v_e1, 'Redactar borrador', current_date - 2);
  insert into eventos (tipo, titulo, expediente_id, inicio) values ('vencimiento', 'Plazo contestación', v_e1, now() + interval '3 days');
  insert into eventos (tipo, titulo, expediente_id, inicio) values ('audiencia', 'Vista', v_e1, now() + interval '5 days');
  insert into movimientos (expediente_id, tipo, concepto, base_eur, estado) values (v_e1, 'provision_fondos', 'Provisión inicial', 500, 'cobrado');
  insert into movimientos (expediente_id, tipo, concepto, base_eur, estado, vence_en) values (v_e1, 'honorario', 'Segundo plazo', 500, 'pendiente', current_date + 15);
  insert into movimientos (expediente_id, tipo, concepto, base_eur, iva_pct, estado) values (v_e1, 'suplido', 'Tasa registro', 40, 0, 'pagado');
  insert into documentos (expediente_id, ruta_storage, nombre_original, visible_cliente) values (v_e1, 'x/1.pdf', 'Borrador pacto.pdf', true);
  insert into documentos (expediente_id, ruta_storage, nombre_original, visible_cliente) values (v_e1, 'x/2.pdf', 'Estrategia interna.pdf', false);
  insert into mensajes (expediente_id, autor, texto) values (v_e1, 'abogado', 'Le adjunto el borrador.');

  d := panel_dashboard();
  assert (d->>'expedientes_activos')::int = 2, 'activos';
  assert (d->>'vencimientos_7d')::int = 1 and (d->>'audiencias_7d')::int = 1, 'agenda 7d';
  assert (d->>'tareas_atrasadas')::int = 1, 'tareas atrasadas';
  assert (d->>'pendiente_cobro_eur')::numeric = 605.00, 'pendiente con IVA: ' || (d->>'pendiente_cobro_eur');
  assert (d->>'ingresos_mes_eur')::numeric = 605.00, 'ingresos mes';
  assert (d->>'gastos_mes_eur')::numeric = 40.00, 'suplido sin IVA';
  assert (d->>'oportunidades_por_validar')::int = 1, 'oportunidades';
  assert notas_expediente(v_e1) is not null, 'abogado lee notas';

  -- Cita del embudo -> aparece en la agenda
  reset role;
  insert into citas (lead_id, inicio, fin) values (v_l1, now() + interval '2 days', now() + interval '2 days 30 minutes') returning id into v_cita;
  update eventos set expediente_id = v_e1 where cita_id = v_cita;
  assert exists (select 1 from eventos where cita_id = v_cita and tipo = 'cita_cliente'), 'cita en agenda';
  update citas set estado = 'cancelada' where id = v_cita;
  assert not exists (select 1 from eventos where cita_id = v_cita), 'cancelada sale de la agenda';

  -- Portal: Cliente Uno ve SOLO lo suyo y lo compartible
  perform set_config('request.jwt.claim.sub', v_u1::text, true);
  set local role authenticated;
  p := portal_resumen();
  assert jsonb_array_length(p) = 1, 'solo su expediente';
  assert jsonb_array_length(p->0->'documentos') = 1, 'solo documentos compartidos';
  assert (p->0->'pagos_pendientes'->0->>'total_eur')::numeric = 605.00, 've su pago pendiente';
  assert (p->0->>'mensajes_no_leidos')::int = 1, 'mensajes';
  assert jsonb_array_length(p->0->'proximos_eventos') = 1, 've la vista, no el vencimiento interno';
  select count(*) into v_n from tareas;          assert v_n = 0, 'no ve tareas';
  select count(*) into v_n from oportunidades;   assert v_n = 0, 'no ve oportunidades';
  select count(*) into v_n from expedientes;     assert v_n = 1, 'tabla: solo su expediente';
  select count(*) into v_n from clientes;        assert v_n = 1, 'solo su ficha';
  assert notas_expediente(v_e1) is null, 'no lee notas internas por función';
  begin
    perform notas_internas from expedientes;
    v_err := 'sin_error';
  exception when insufficient_privilege then v_err := 'denegado';
  end;
  assert v_err = 'denegado', 'columna de notas internas bloqueada';
  perform portal_enviar_mensaje(v_e1, 'Gracias, lo reviso.');
  begin perform portal_enviar_mensaje(v_e2, 'intrusión'); v_err := 'sin_error';
  exception when others then v_err := sqlerrm; end;
  assert v_err = 'no_autorizado', 'no escribe en expedientes ajenos';
  assert not panel_dashboard() ? 'nada' and (panel_dashboard()->>'expedientes_activos')::int = 1, 'dashboard filtrado por RLS';
  begin perform abrir_expediente(v_l2, 'x'); v_err := 'sin_error';
  exception when others then v_err := sqlerrm; end;
  assert v_err = 'no_autorizado', 'cliente no abre expedientes';

  -- Cliente Dos no ve nada de Cliente Uno
  perform set_config('request.jwt.claim.sub', v_u2::text, true);
  p := portal_resumen();
  assert jsonb_array_length(p) = 1 and p->0->>'titulo' = 'Cliente Dos · reclamación', 'aislamiento entre clientes';
  reset role;

  raise notice 'TODAS LAS PRUEBAS DE GESTIÓN Y PORTAL SUPERADAS';
end $$;

rollback;
