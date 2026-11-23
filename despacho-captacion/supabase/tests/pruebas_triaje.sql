-- Pruebas funcionales del triaje. Ejecutar en una base de PRUEBAS (crea y borra datos ficticios).
-- psql -1 -v ON_ERROR_STOP=1 -f pruebas_triaje.sql   (todo dentro de una transacción que se revierte)
set local search_path = despacho, extensions, public;

do $$
declare r record; v_err boolean := false;
begin
  assert normalizar_nombre('Construcciones Pérez, S.L.U.') = normalizar_nombre('CONSTRUCCIONES PEREZ SL'), 'normalización';

  insert into clientes(id,tipo,nombre,nif,email) values
   ('00000000-0000-0000-0000-00000000000a','juridica','Alfa Distribución SL','B11111111','a@ejemplo.test'),
   ('00000000-0000-0000-0000-00000000000b','juridica','Construcciones Pérez, S.L.U.','B22222222','b@ejemplo.test'),
   ('00000000-0000-0000-0000-00000000000c','fisica','María López','12345678Z','c@ejemplo.test');
  insert into leads(id,cliente_id,materia_codigo,estado) values ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000a','mer_deudas','convertido');
  insert into contrapartes(lead_id,nombre) values ('10000000-0000-0000-0000-000000000001','CONSTRUCCIONES PEREZ SL');

  -- 1. Quien fue contraparte pide cita -> revisión por conflicto
  insert into leads(id,cliente_id,materia_codigo,documentacion_aportada,acepta_condiciones,es_empresa_o_autonomo)
   values ('20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000000b','mer_contratos',true,true,true);
  select * into r from evaluar_lead('20000000-0000-0000-0000-000000000001');
  assert r.estado = 'revision' and r.conflictos_pendientes = 1, 'caso 1 conflicto';

  -- 2. Mercantil con plazo a 3 días, docs, cuantía alta -> apto + alerta
  insert into leads(id,cliente_id,materia_codigo,fecha_limite,cuantia_eur,documentacion_aportada,acepta_condiciones)
   values ('20000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000000c','mer_pactos_socios',current_date+3,20000,true,true);
  select * into r from evaluar_lead('20000000-0000-0000-0000-000000000002');
  assert r.estado = 'apto' and r.puntuacion = 90 and r.alerta_plazo, 'caso 2 apto';

  -- 3. Penal con detenido -> derivado
  insert into leads(id,cliente_id,materia_codigo) values ('20000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-00000000000c','der_penal_detenido');
  select * into r from evaluar_lead('20000000-0000-0000-0000-000000000003');
  assert r.estado = 'derivado', 'caso 3 derivar';

  -- 4. Complementaria con docs y condiciones (45) -> revisión
  insert into leads(id,cliente_id,materia_codigo,documentacion_aportada,acepta_condiciones) values ('20000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-00000000000c','civ_arrendamientos',true,true);
  select * into r from evaluar_lead('20000000-0000-0000-0000-000000000004');
  assert r.estado = 'revision' and r.puntuacion = 45, 'caso 4 revisión';

  -- 5. Citas solapadas -> error; cancelada libera el hueco
  insert into citas(lead_id,inicio,fin) values ('20000000-0000-0000-0000-000000000002','2030-11-25 18:00+01','2030-11-25 18:30+01');
  begin
    insert into citas(lead_id,inicio,fin) values ('20000000-0000-0000-0000-000000000004','2030-11-25 18:15+01','2030-11-25 18:45+01');
  exception when exclusion_violation then v_err := true;
  end;
  assert v_err, 'caso 5 solape';
  update citas set estado = 'cancelada' where lead_id = '20000000-0000-0000-0000-000000000002';
  insert into citas(lead_id,inicio,fin) values ('20000000-0000-0000-0000-000000000004','2030-11-25 18:15+01','2030-11-25 18:45+01');

  -- 6. Días hábiles con festivos de La Rioja (7 y 8 dic 2026)
  assert dias_habiles_hasta('2026-12-11','2026-12-04') = 3, 'caso 6 festivos';

  raise notice 'TODAS LAS PRUEBAS SUPERADAS';
end $$;

rollback;
