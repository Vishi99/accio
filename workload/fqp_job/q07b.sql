SELECT MIN(n.name) AS of_person,
       MIN(t.title) AS biography_movie
FROM db3.aka_name AS an,
     db3.cast_info AS ci,
     db3.info_type AS it,
     db4.link_type AS lt,
     db4.movie_link AS ml,
     db3.name AS n,
     db3.person_info AS pi,
     db4.title AS t
WHERE an.name LIKE '%a%'
  AND it.info ='mini biography'
  AND lt.link ='features'
  AND n.name_pcode_cf LIKE 'D%'
  AND n.gender='m'
  AND pi.note ='Volker Boehm'
  AND t.production_year BETWEEN 1980 AND 1984
  AND n.id = an.person_id
  AND n.id = pi.person_id
  AND ci.person_id = n.id
  AND t.id = ci.movie_id
  AND ml.linked_movie_id = t.id
  AND lt.id = ml.link_type_id
  AND it.id = pi.info_type_id
  AND pi.person_id = an.person_id
  AND pi.person_id = ci.person_id
  AND an.person_id = ci.person_id
  AND ci.movie_id = ml.linked_movie_id

