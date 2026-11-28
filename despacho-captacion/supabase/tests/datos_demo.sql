-- Datos FICTICIOS de demostración para ver el panel en local. No usar en producción.
set search_path = despacho, extensions, public;
insert into abogados values ('99999999-9999-9999-9999-999999999999', 'Abogado') on conflict do nothing;
do $$
declare c uuid; l uuid; e uuid; i int; nombres text[] := array['Vinos del Iregua SL','Talleres Cidacos SA','María Sáenz Ruiz','Construcciones Najerilla SL','Pedro Ochoa Martínez'];
  mats text[] := array['mer_pactos_socios','mer_deudas','civ_arrendamientos','mer_contratos','tri_requerimientos'];
  estados estado_expediente[] := array['en_tramite','urgente','abierto','pendiente_revision','en_tramite'];
begin
  for i in 1..5 loop
    insert into clientes (tipo, nombre, email, nif) values ((case when i in (3,5) then 'fisica' else 'juridica' end)::tipo_persona, nombres[i], 'demo'||i||'@ejemplo.test', null) returning id into c;
    insert into leads (cliente_id, materia_codigo, estado) values (c, mats[i], 'convertido') returning id into l;
    insert into expedientes (cliente_id, lead_id, materia_codigo, titulo, estado, honorarios_pactados, hoja_encargo_firmada, contraparte, organo)
      values (c, l, mats[i], nombres[i] || ' · ' || (select m.nombre from materias m where m.codigo = mats[i]), estados[i], 600 + i*300, i <> 4,
              case i when 2 then 'Recambios Ebro SL' when 1 then 'Socio minoritario' else null end,
              case i when 2 then 'Juzgado de Primera Instancia nº 2 de Logroño' when 5 then 'AEAT · Delegación de La Rioja' else null end) returning id into e;
    insert into eventos (tipo, titulo, expediente_id, inicio) values
      ((array['vencimiento','audiencia','reunion','vencimiento','vencimiento'])[i]::tipo_evento,
       (array['Plazo contestación','Audiencia previa','Reunión con socios','Revisión de borrador','Contestar requerimiento'])[i], e,
       date_trunc('day', now()) + ((i*3) || ' days')::interval + interval '10 hours');
    insert into tareas (expediente_id, titulo, vence_en) values (e, (array['Redactar pacto','Preparar prueba documental','Revisar contrato de arrendamiento','Enviar borrador al cliente','Reunir facturas'])[i], current_date + (i - 3));
    insert into movimientos (expediente_id, tipo, concepto, base_eur, estado, fecha) values (e, 'provision_fondos', 'Provisión inicial', 200 + i*50, 'cobrado', current_date - i);
    insert into movimientos (expediente_id, tipo, concepto, base_eur, estado, fecha, vence_en) values (e, 'honorario', 'Segundo plazo', 300, (case when i % 2 = 0 then 'pendiente' else 'cobrado' end)::estado_movimiento, current_date - 1, current_date + 10);
  end loop;
  insert into movimientos (expediente_id, tipo, concepto, base_eur, iva_pct, estado) select id, 'suplido', 'Tasa judicial', 150, 0, 'pagado' from expedientes where estado = 'urgente';
  insert into oportunidades (expediente_id, materia_codigo, necesidad, evidencia, confianza)
    select id, 'mer_juntas', 'No se levantan actas de las juntas', '"las juntas las hacemos de palabra, nunca firmamos nada"', 0.82 from expedientes where titulo like 'Vinos%';
  insert into mensajes (expediente_id, autor, texto) select id, 'cliente', '¿Cómo va lo del requerimiento? Me preocupa el plazo.' from expedientes where titulo like 'Pedro%';
end $$;
