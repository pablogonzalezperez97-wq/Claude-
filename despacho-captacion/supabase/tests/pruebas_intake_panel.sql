-- Pruebas del formulario (registrar_lead) y del panel. Base de PRUEBAS; todo se revierte.
-- psql -1 -v ON_ERROR_STOP=1 -f pruebas_intake_panel.sql
set local search_path = despacho, extensions, public;

do $$
declare r jsonb; v_lead uuid; v_conf uuid; v_err text; v_n int; p jsonb;
begin
  p := '{"tipo":"juridica","nombre":"Beta Logística SL","nif":"B-26.000.001","email":"Gerencia@Beta.test",
         "materia":"mer_pactos_socios","descripcion":"Discrepancias entre socios sobre el reparto de dividendos y salida de un socio.",
         "cuantia_eur":30000,"documentacion_disponible":true,"acepta_privacidad":true,"acepta_condiciones":true,
         "contrapartes":[{"nombre":"Juan Ruiz Martínez","nif":"16000000A"}]}';

  -- 1. Alta correcta -> reservar (30+15+15+10+10 = 80)
  r := registrar_lead(p, '127.0.0.1', 'test');
  assert r->>'resultado' = 'reservar', 'alta directa: ' || r::text;
  assert (select count(*) from consentimientos where lead_id = (r->>'lead_id')::uuid) = 3, 'consentimientos';
  assert (select email from clientes where nif_norm = 'B26000001') = 'gerencia@beta.test', 'email normalizado';

  -- 2. Validaciones
  begin perform registrar_lead(p - 'acepta_privacidad'); exception when others then v_err := sqlerrm; end;
  assert v_err = 'falta_privacidad', 'privacidad: ' || coalesce(v_err,'null');
  v_err := null;
  begin perform registrar_lead(jsonb_set(p, '{materia}', '"inventada"')); exception when others then v_err := sqlerrm; end;
  assert v_err = 'materia_invalida', 'materia';
  v_err := null;
  begin perform registrar_lead(p - 'nif'); exception when others then v_err := sqlerrm; end;
  assert v_err = 'nif_obligatorio_juridica', 'nif juridica';

  -- 3. Mismo NIF con otro nombre: se vincula, no sobrescribe
  r := registrar_lead(jsonb_set(jsonb_set(p, '{nombre}', '"Nombre Falso SA"'), '{email}', '"otro@beta.test"'));
  assert (select nombre from clientes where nif_norm = 'B26000001') = 'Beta Logística SL', 'no sobrescribe';
  assert (select count(*) from clientes where nif_norm = 'B26000001') = 1, 'sin duplicar';

  -- 4. Límite: 3 por cliente o email en 24 h (el cliente B26000001 ya lleva 2)
  perform registrar_lead(p);
  v_err := null;
  begin perform registrar_lead(p); exception when others then v_err := sqlerrm; end;
  assert v_err = 'limite_solicitudes', 'limite';

  -- 5. La contraparte (Juan Ruiz) pide ahora cita -> en_revision, sin revelar conflicto
  r := registrar_lead('{"tipo":"fisica","nombre":"Juan Ruiz Martinez","email":"juan@ruiz.test","materia":"mer_pactos_socios",
        "descripcion":"Quiero salir de la sociedad y que me paguen mis participaciones.","acepta_privacidad":true,"acepta_condiciones":true}');
  assert r->>'resultado' = 'en_revision', 'conflicto oculto: ' || r::text;
  assert not (r ? 'conflictos') and not (r ? 'puntuacion'), 'no filtra datos';
  v_lead := (r->>'lead_id')::uuid;

  -- 6. Derivación
  r := registrar_lead('{"tipo":"fisica","nombre":"Ana Gil","email":"ana@gil.test","materia":"der_violencia_genero",
        "descripcion":"Necesito ayuda urgente con una situación de violencia.","acepta_privacidad":true,"acepta_condiciones":true}');
  assert r->>'resultado' = 'derivar' and r->>'motivo_derivacion' is not null, 'derivar';

  -- 7. Panel: sin ser abogado no ve nada; siendo abogado sí
  insert into abogados values ('99999999-9999-9999-9999-999999999999', 'Abogado');
  perform set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
  set local role authenticated;
  assert jsonb_array_length(panel_pendientes()) = 0, 'no abogado no ve';
  v_err := null;
  begin perform decidir_lead(v_lead, 'aceptar'); exception when others then v_err := sqlerrm; end;
  assert v_err = 'no_autorizado', 'no abogado no decide';

  perform set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
  select jsonb_array_length(panel_pendientes()) into v_n;
  assert v_n >= 4, 'abogado ve pendientes: ' || v_n;

  -- 8. No puede aceptar con conflicto pendiente; tras descartarlo, sí
  v_err := null;
  begin perform decidir_lead(v_lead, 'aceptar'); exception when others then v_err := sqlerrm; end;
  assert v_err = 'conflictos_sin_resolver', 'bloqueo por conflicto';
  for v_conf in select id from conflictos where lead_id = v_lead loop
    perform decidir_conflicto(v_conf, 'descartado', 'Homónimo, no es la misma persona');
  end loop;
  assert decidir_lead(v_lead, 'aceptar', 'Revisado') = 'apto', 'aceptar tras descartar';

  -- 9. Conflicto confirmado descarta el asunto
  reset role;
  r := registrar_lead('{"tipo":"fisica","nombre":"Juan Ruiz Martínez","nif":"16000000A","email":"juan2@ruiz.test","materia":"mer_contratos",
        "descripcion":"Revisión de un contrato de distribución con un proveedor.","acepta_privacidad":true,"acepta_condiciones":true}');
  v_lead := (r->>'lead_id')::uuid;
  set local role authenticated;
  for v_conf in select id from conflictos where lead_id = v_lead limit 1 loop
    perform decidir_conflicto(v_conf, 'confirmado');
  end loop;
  reset role;
  assert (select estado from leads where id = v_lead) = 'descartado', 'confirmado descarta';

  raise notice 'TODAS LAS PRUEBAS DE INTAKE Y PANEL SUPERADAS';
end $$;

rollback;
