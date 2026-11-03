\set ON_ERROR_STOP on
SET search_path=clinic,public;
ANALYZE;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM appointments WHERE patient_id=1 ORDER BY starts_at DESC;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM waitlist_entries WHERE specialty_id=1 AND status='waiting' ORDER BY created_at,id LIMIT 1;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM slot_holds WHERE status='active' AND expires_at<=now();
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM care_actions WHERE episode_id=1 AND status IN ('assigned','booked');
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM patients WHERE lower(full_name)=lower('Вымышленный Пациент 1') AND birth_date='1990-01-02';
