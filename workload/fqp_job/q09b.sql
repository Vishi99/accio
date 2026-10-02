SELECT MIN(an.name) AS alternative_name,
       MIN(chn.name) AS voiced_character,
       MIN(n.name) AS voicing_actress,
       MIN(t.title) AS american_movie
FROM db3.aka_name AS an,
     db3.char_name AS chn,
     db3.cast_info AS ci,
     db1.company_name AS cn,
     db1.movie_companies AS mc,
     db3.name AS n,
     db3.role_type AS rt,
     db4.title AS t
WHERE ci.note = '(voice)'
  AND cn.country_code ='[us]'
  AND mc.note LIKE '%(200%)%'
  AND (mc.note LIKE '%(USA)%'
       OR mc.note LIKE '%(worldwide)%')
  AND n.gender ='f'
  AND n.name LIKE '%Angel%'
  AND rt.role ='actress'
  AND t.production_year BETWEEN 2007 AND 2010
  AND ci.movie_id = t.id
  AND t.id = mc.movie_id
  AND ci.movie_id = mc.movie_id
  AND mc.company_id = cn.id
  AND ci.role_id = rt.id
  AND n.id = ci.person_id
  AND chn.id = ci.person_role_id
  AND an.person_id = n.id
  AND an.person_id = ci.person_id

