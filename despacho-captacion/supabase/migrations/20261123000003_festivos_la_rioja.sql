-- =====================================================================
-- Festivos laborales de La Rioja (no cuentan como días hábiles ni se agendan)
-- 2026: Acuerdo del Gobierno de La Rioja, BOR nº 89 de 12-05-2025 (12 fiestas).
-- 2027: BOR de 08-05-2026. Las 8 primeras están confirmadas; las 4 marcadas
--       "(verificar)" se deducen del calendario y hay que contrastarlas con el BOR.
-- Festivos LOCALES: pendientes de saber el municipio del despacho.
-- =====================================================================

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
