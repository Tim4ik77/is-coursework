\set ON_ERROR_STOP on
SET search_path=clinic,public;
CREATE FUNCTION pg_temp.must_fail(sql text, expected text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 BEGIN
  EXECUTE sql;
  SET CONSTRAINTS ALL IMMEDIATE;
 EXCEPTION WHEN OTHERS THEN
  IF position(expected IN SQLERRM)=0 THEN RAISE EXCEPTION 'Wrong error: %, expected %',SQLERRM,expected; END IF;
  RETURN;
 END;
 RAISE EXCEPTION 'Expected rejection: %',sql;
END $$;
BEGIN;
SELECT pg_temp.must_fail($q$SELECT book_appointment(4,2,'self',8)$q$,'quota');
SELECT pg_temp.must_fail($q$SELECT book_appointment(4,6,'self',8)$q$,'quota');
SELECT pg_temp.must_fail($q$UPDATE medical_notes SET diagnosis='changed' WHERE id=1$q$,'planned');
SELECT pg_temp.must_fail($q$DELETE FROM note_addenda WHERE id=1$q$,'append-only');
SELECT pg_temp.must_fail($q$UPDATE questions SET question_text='changed' WHERE id=1$q$,'immutable');
SELECT pg_temp.must_fail($q$UPDATE questionnaire_answers SET questionnaire_id=999 WHERE submission_id=1$q$,'foreign key');
SELECT pg_temp.must_fail($q$CALL set_episode_status(1,'closed')$q$,'confirmation');
SELECT pg_temp.must_fail($q$UPDATE care_actions SET target_specialty_id=1 WHERE id=1$q$,'does not match');
SELECT pg_temp.must_fail($q$UPDATE appointments SET status='planned' WHERE id=1$q$,'immutable');
SELECT pg_temp.must_fail($q$UPDATE doctor_schedules SET start_time='08:00' WHERE id=1$q$,'immutable');
SELECT pg_temp.must_fail($q$UPDATE daily_quotas SET slot_limit=0 WHERE schedule_id=1 AND booking_type='self'$q$,'sum');
SELECT pg_temp.must_fail($q$INSERT INTO patients(user_id,full_name,birth_date,oms_number) VALUES(8,'Duplicate','2000-01-01','0000000000000001')$q$,'unique');
SELECT pg_temp.must_fail($q$SELECT move_appointment(3,1,6)$q$,'unique');
DO $$ BEGIN IF (SELECT status FROM appointments WHERE id=3)<>'planned' THEN RAISE EXCEPTION 'Move failed to roll back'; END IF; END $$;
SELECT confirm_hold(1,3);
SET CONSTRAINTS ALL IMMEDIATE;
DO $$ BEGIN IF (SELECT count(*) FROM appointments WHERE status<>'cancelled' AND booking_type='self')<>3 THEN RAISE EXCEPTION 'Hold double counted'; END IF; END $$;
SET CONSTRAINTS ALL DEFERRED;
CALL cancel_appointment(2);
DO $$ BEGIN IF (SELECT status FROM care_actions WHERE id=1)<>'assigned' THEN RAISE EXCEPTION 'Referral not restored'; END IF; END $$;
-- Released quotas permit borrowing, but restricted specialties still require a referral.
UPDATE doctor_schedules SET release_at=now()-interval '1 minute';
SELECT pg_temp.must_fail($q$SELECT book_appointment(4,6,'self',8)$q$,'Referral required');
SELECT pg_temp.must_fail($q$SELECT book_appointment(2,7,'referral',6,1)$q$,'Invalid referral');
SELECT pg_temp.must_fail($q$SELECT book_appointment(4,2,'self',8)$q$,'unique');
SELECT pg_temp.must_fail($q$SELECT book_appointment(1,6,'referral',5,1)$q$,'exclusion');
SELECT episode_summary(1);
SELECT * FROM doctor_statistics(current_date,current_date+10);
SELECT * FROM available_slots(4,1,'self',now(),now()+interval '10 days');
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
\echo Integrity scenarios passed
