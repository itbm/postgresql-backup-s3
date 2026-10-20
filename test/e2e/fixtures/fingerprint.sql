-- Prints one stable line per user-visible object. Two databases with identical
-- output hold the same schema and data. Used to compare a source database with
-- its restored copy.

WITH tables AS (
  SELECT n.nspname, c.relname
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'm')
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND n.nspname NOT LIKE 'pg_toast%'
)
SELECT format('table %I.%I %s', nspname, relname,
  (xpath('/row/h/text()', query_to_xml(format(
    'SELECT count(*) || '':'' || md5(coalesce(string_agg(x::text, E''\n'' ORDER BY x::text), '''')) AS h FROM %I.%I x',
    nspname, relname), false, true, '')))[1]::text)
FROM tables
UNION ALL
SELECT format('view %I.%I %s', schemaname, viewname, md5(definition))
FROM pg_views
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
UNION ALL
SELECT format('function %I.%I(%s) %s', n.nspname, p.proname,
  pg_get_function_identity_arguments(p.oid), md5(p.prosrc))
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
UNION ALL
SELECT format('sequence %I.%I %s', schemaname, sequencename, coalesce(last_value::text, 'null'))
FROM pg_sequences
UNION ALL
SELECT format('index %I.%I %s', schemaname, indexname, md5(indexdef))
FROM pg_indexes
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
UNION ALL
SELECT format('constraint %s %I %s', conrelid::regclass, conname, md5(pg_get_constraintdef(oid)))
FROM pg_constraint
WHERE connamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
UNION ALL
SELECT format('trigger %s %I', tgrelid::regclass, tgname)
FROM pg_trigger
WHERE NOT tgisinternal
UNION ALL
SELECT format('largeobject %s %s', oid, md5(lo_get(oid)))
FROM pg_largeobject_metadata
UNION ALL
SELECT format('comment %s %s', c.oid::regclass, md5(d.description))
FROM pg_description d
JOIN pg_class c ON c.oid = d.objoid
WHERE d.classoid = 'pg_class'::regclass AND d.objsubid = 0
ORDER BY 1;
