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
