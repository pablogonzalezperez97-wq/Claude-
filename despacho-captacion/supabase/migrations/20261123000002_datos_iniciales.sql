-- =====================================================================
-- Datos iniciales: parámetros, franjas y catálogo de materias
-- (espejo de config/negocio.yaml, validado por el abogado el 23-11-2026)
-- =====================================================================

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
