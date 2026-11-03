SET search_path = clinic, public;
-- Functions use caller permissions. The future backend must authenticate actors
-- and authorize patient/doctor scope before calling them; no SECURITY DEFINER.
CREATE FUNCTION register_patient(p_login text,p_hash text,p_name text,p_birth date,p_oms text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE uid bigint; pid bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(742031,2);
 IF EXISTS(SELECT 1 FROM patients WHERE lower(full_name)=lower(p_name) AND birth_date=p_birth) THEN
  RAISE NOTICE 'Possible duplicate name and birth date';
 END IF;
 INSERT INTO users(login,password_hash,role) VALUES(p_login,p_hash,'patient') RETURNING id INTO uid;
 INSERT INTO patients(user_id,full_name,birth_date,oms_number) VALUES(uid,p_name,p_birth,p_oms) RETURNING id INTO pid;
 RETURN pid;
END $$;

CREATE PROCEDURE generate_slots(p_schedule bigint) LANGUAGE plpgsql AS $$
DECLARE d doctor_schedules; t timestamptz; finish timestamptz;
BEGIN
 PERFORM pg_advisory_xact_lock(742031,2);
 SELECT * INTO STRICT d FROM doctor_schedules WHERE id=p_schedule;
 IF EXISTS(SELECT 1 FROM time_slots WHERE schedule_id=p_schedule) THEN RAISE EXCEPTION 'Schedule already has slots'; END IF;
 t:=(d.work_date+d.start_time) AT TIME ZONE 'Europe/Moscow';
 finish:=(d.work_date+d.end_time) AT TIME ZONE 'Europe/Moscow';
 WHILE t+make_interval(mins=>d.slot_minutes)<=finish LOOP
  IF NOT EXISTS(SELECT 1 FROM schedule_breaks b WHERE b.schedule_id=p_schedule AND
   tstzrange(t,t+make_interval(mins=>d.slot_minutes),'[)') && tstzrange((d.work_date+b.start_time) AT TIME ZONE 'Europe/Moscow',(d.work_date+b.end_time) AT TIME ZONE 'Europe/Moscow','[)')) THEN
   INSERT INTO time_slots(schedule_id,starts_at,ends_at) VALUES(p_schedule,t,t+make_interval(mins=>d.slot_minutes));
  END IF;
  t:=t+make_interval(mins=>d.slot_minutes);
 END LOOP;
END $$;

CREATE FUNCTION book_appointment(p_patient bigint,p_slot bigint,p_type text,p_actor bigint,p_action bigint DEFAULT NULL,p_held boolean DEFAULT false)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE aid bigint; d bigint; lim integer; used integer; rel timestamptz;
BEGIN
 PERFORM pg_advisory_xact_lock(742031,2);
 IF NOT EXISTS(SELECT 1 FROM users WHERE id=p_actor AND NOT is_blocked) THEN RAISE EXCEPTION 'Actor is blocked or missing'; END IF;
 SELECT s.schedule_id INTO STRICT d FROM time_slots s WHERE s.id=p_slot;
 SELECT q.slot_limit,s.release_at INTO STRICT lim,rel FROM daily_quotas q JOIN doctor_schedules s ON s.id=q.schedule_id WHERE q.schedule_id=d AND q.booking_type=p_type;
 SELECT count(*) INTO used FROM appointments a JOIN time_slots s ON s.id=a.slot_id WHERE s.schedule_id=d AND a.booking_type=p_type AND a.status<>'cancelled';
 IF rel>clock_timestamp() AND used>=lim THEN RAISE EXCEPTION 'Daily quota exhausted'; END IF;
 INSERT INTO appointments(patient_id,slot_id,care_action_id,created_by_user_id,booking_type,status)
 VALUES(p_patient,p_slot,p_action,p_actor,p_type,CASE WHEN p_held THEN 'held' ELSE 'planned' END) RETURNING id INTO aid;
 RETURN aid;
END $$;

CREATE PROCEDURE cancel_appointment(p_appointment bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(742031,2);
 IF NOT EXISTS(SELECT 1 FROM appointments WHERE id=p_appointment AND status='planned') THEN RAISE EXCEPTION 'Planned appointment not found'; END IF;
 UPDATE appointments SET status='cancelled' WHERE id=p_appointment;
END $$;

CREATE FUNCTION move_appointment(p_appointment bigint,p_slot bigint,p_actor bigint) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE a appointments; result bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(742031,2);
 SELECT * INTO STRICT a FROM appointments WHERE id=p_appointment AND status='planned';
 CALL cancel_appointment(a.id);
 result:=book_appointment(a.patient_id,p_slot,a.booking_type,p_actor,a.care_action_id);
 IF a.booking_type='self' AND a.episode_id IS NOT NULL THEN UPDATE appointments SET episode_id=a.episode_id WHERE id=result; END IF;
 RETURN result;
 -- Any failure rolls back cancellation as part of the same statement.
END $$;

CREATE PROCEDURE complete_appointment(p_appointment bigint,p_episode bigint,p_doctor bigint,
 p_complaints text,p_examination text,p_diagnosis text,p_recommendations text) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(742031,2);
 UPDATE appointments SET episode_id=p_episode WHERE id=p_appointment AND status='planned';
 IF NOT FOUND THEN RAISE EXCEPTION 'Planned appointment not found'; END IF;
 INSERT INTO medical_notes(appointment_id,author_doctor_id,complaints,examination,diagnosis,recommendations)
 VALUES(p_appointment,p_doctor,p_complaints,p_examination,p_diagnosis,p_recommendations)
 ON CONFLICT(appointment_id) DO UPDATE SET complaints=excluded.complaints,examination=excluded.examination,diagnosis=excluded.diagnosis,recommendations=excluded.recommendations;
 UPDATE appointments SET status='completed' WHERE id=p_appointment;
END $$;

CREATE PROCEDURE expire_holds() LANGUAGE plpgsql AS $$
DECLARE h record;
BEGIN
 PERFORM pg_advisory_xact_lock(742031,2);
 FOR h IN SELECT * FROM slot_holds WHERE status='active' AND expires_at<=clock_timestamp() LOOP
  UPDATE slot_holds SET status='expired' WHERE id=h.id;
  UPDATE appointments SET status='cancelled' WHERE id=h.appointment_id;
  UPDATE waitlist_entries SET status='expired' WHERE id=h.waitlist_entry_id;
 END LOOP;
END $$;

CREATE FUNCTION offer_slot(p_slot bigint,p_actor bigint) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE w record; s record; aid bigint; hid bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(742031,2);
 CALL expire_holds();
 SELECT t.*,d.specialty_id INTO STRICT s FROM time_slots t JOIN doctor_schedules d ON d.id=t.schedule_id WHERE t.id=p_slot;
 IF EXISTS(SELECT 1 FROM appointments WHERE slot_id=p_slot AND status<>'cancelled') THEN RETURN NULL; END IF;
 FOR w IN SELECT * FROM waitlist_entries WHERE status='waiting' AND specialty_id=s.specialty_id
   AND preferred_from<=s.starts_at AND preferred_until>=s.ends_at ORDER BY created_at,id LOOP
  BEGIN
   aid:=book_appointment(w.patient_id,p_slot,w.booking_type,p_actor,w.care_action_id,true);
   INSERT INTO slot_holds(waitlist_entry_id,appointment_id,expires_at)
    VALUES(w.id,aid,clock_timestamp()+make_interval(mins=>(SELECT hold_minutes FROM system_settings))) RETURNING id INTO hid;
   UPDATE waitlist_entries SET status='offered' WHERE id=w.id;
   RETURN hid;
  EXCEPTION WHEN exclusion_violation OR unique_violation OR raise_exception THEN
   -- An ineligible candidate must not block the next eligible patient.
   CONTINUE;
  END;
 END LOOP;
 RETURN NULL;
END $$;

CREATE FUNCTION confirm_hold(p_hold bigint,p_patient bigint) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE h slot_holds;
BEGIN
 PERFORM pg_advisory_xact_lock(742031,2);
 SELECT * INTO STRICT h FROM slot_holds WHERE id=p_hold AND status='active';
 IF h.expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'Offer expired'; END IF;
 IF NOT EXISTS(SELECT 1 FROM appointments WHERE id=h.appointment_id AND patient_id=p_patient) THEN RAISE EXCEPTION 'Offer belongs to another patient'; END IF;
 UPDATE slot_holds SET status='confirmed' WHERE id=h.id;
 UPDATE appointments SET status='planned' WHERE id=h.appointment_id;
 UPDATE waitlist_entries SET status='accepted' WHERE id=h.waitlist_entry_id;
 RETURN h.appointment_id;
END $$;

CREATE PROCEDURE decline_hold(p_hold bigint,p_patient bigint) LANGUAGE plpgsql AS $$
DECLARE h slot_holds;
BEGIN
 PERFORM pg_advisory_xact_lock(742031,2);
 SELECT * INTO STRICT h FROM slot_holds WHERE id=p_hold AND status='active';
 IF NOT EXISTS(SELECT 1 FROM appointments WHERE id=h.appointment_id AND patient_id=p_patient) THEN RAISE EXCEPTION 'Offer belongs to another patient'; END IF;
 UPDATE slot_holds SET status='declined' WHERE id=h.id;
 UPDATE appointments SET status='cancelled' WHERE id=h.appointment_id;
 UPDATE waitlist_entries SET status='cancelled' WHERE id=h.waitlist_entry_id;
END $$;

CREATE PROCEDURE close_inactive_episodes() LANGUAGE plpgsql AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(742031,2);
 UPDATE episodes e SET status='closed' WHERE e.status='active'
 AND e.last_activity_at<clock_timestamp()-make_interval(days=>(SELECT inactivity_days FROM system_settings))
 AND NOT EXISTS(SELECT 1 FROM care_actions c WHERE c.episode_id=e.id AND c.status IN ('assigned','booked'))
 AND NOT EXISTS(SELECT 1 FROM appointments a WHERE a.episode_id=e.id AND a.status IN ('planned','held') AND a.ends_at>clock_timestamp());
END $$;

CREATE FUNCTION episode_summary(p_episode bigint) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE result jsonb;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM episodes WHERE id=p_episode) THEN RAISE EXCEPTION 'Episode not found'; END IF;
 SELECT jsonb_build_object('episode',to_jsonb(e),
 'appointments',coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.starts_at) FROM appointments a WHERE a.episode_id=e.id),'[]'::jsonb),
 'actions',coalesce((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.id) FROM care_actions c WHERE c.episode_id=e.id),'[]'::jsonb),
 'notes',coalesce((SELECT jsonb_agg(to_jsonb(n)) FROM medical_notes n JOIN appointments a ON a.id=n.appointment_id WHERE a.episode_id=e.id),'[]'::jsonb),
 'addenda',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at) FROM note_addenda x JOIN medical_notes n ON n.id=x.medical_note_id JOIN appointments a ON a.id=n.appointment_id WHERE a.episode_id=e.id),'[]'::jsonb),
 'results',coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.performed_at) FROM study_results r JOIN care_actions c ON c.id=r.care_action_id WHERE c.episode_id=e.id),'[]'::jsonb)) INTO result FROM episodes e WHERE e.id=p_episode;
 INSERT INTO audit_log(action,entity_type,entity_id) VALUES('READ','episodes',p_episode);
 RETURN result;
END $$;

CREATE FUNCTION doctor_statistics(p_from date,p_to date)
RETURNS TABLE(doctor_id bigint,slots bigint,occupied bigint,cancelled bigint,no_show bigint,load_percent numeric,mean_wait interval)
LANGUAGE plpgsql AS $$
BEGIN
 IF p_from>p_to THEN RAISE EXCEPTION 'Invalid date interval'; END IF;
 RETURN QUERY WITH cap AS (
  SELECT d.doctor_id,count(*) n FROM doctor_schedules d JOIN time_slots t ON t.schedule_id=d.id WHERE d.work_date BETWEEN p_from AND p_to GROUP BY d.doctor_id
 ), stats AS (
  SELECT d.doctor_id,count(*) FILTER(WHERE a.status<>'cancelled') n,
   count(*) FILTER(WHERE a.status='cancelled') c,count(*) FILTER(WHERE a.status='no_show') ns,
   avg(a.starts_at-a.created_at) FILTER(WHERE a.status NOT IN ('cancelled','held')) w
  FROM appointments a JOIN time_slots t ON t.id=a.slot_id JOIN doctor_schedules d ON d.id=t.schedule_id
  WHERE d.work_date BETWEEN p_from AND p_to GROUP BY d.doctor_id
 ) SELECT cap.doctor_id,cap.n,coalesce(stats.n,0),coalesce(stats.c,0),coalesce(stats.ns,0),round(100.0*coalesce(stats.n,0)/nullif(cap.n,0),2),stats.w FROM cap LEFT JOIN stats USING(doctor_id);
END $$;

CREATE PROCEDURE set_episode_status(p_episode bigint,p_status text,p_confirm_unfinished boolean DEFAULT false) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(742031,2);
 IF p_status='closed' AND NOT p_confirm_unfinished AND (
 EXISTS(SELECT 1 FROM care_actions WHERE episode_id=p_episode AND status IN ('assigned','booked')) OR
 EXISTS(SELECT 1 FROM appointments WHERE episode_id=p_episode AND status IN ('held','planned') AND ends_at>clock_timestamp())) THEN
  RAISE EXCEPTION 'Explicit confirmation required for unfinished episode';
 END IF;
 UPDATE episodes SET status=p_status,last_activity_at=clock_timestamp() WHERE id=p_episode;
 IF NOT FOUND THEN RAISE EXCEPTION 'Episode not found'; END IF;
END $$;

CREATE FUNCTION available_slots(p_patient bigint,p_specialty bigint,p_type text,p_from timestamptz,p_until timestamptz,p_action bigint DEFAULT NULL)
RETURNS TABLE(slot_id bigint,doctor_id bigint,starts_at timestamptz,ends_at timestamptz) LANGUAGE plpgsql AS $$
BEGIN
 RETURN QUERY SELECT t.id,d.doctor_id,t.starts_at,t.ends_at FROM time_slots t
 JOIN doctor_schedules d ON d.id=t.schedule_id JOIN specialties s ON s.id=d.specialty_id
 JOIN daily_quotas q ON q.schedule_id=d.id AND q.booking_type=p_type
 WHERE s.id=p_specialty AND t.starts_at>=p_from AND t.ends_at<=p_until AND t.starts_at>clock_timestamp()
 AND NOT EXISTS(SELECT 1 FROM appointments a WHERE a.slot_id=t.id AND a.status<>'cancelled')
 AND NOT EXISTS(SELECT 1 FROM appointments a WHERE a.patient_id=p_patient AND a.status<>'cancelled' AND tstzrange(a.starts_at,a.ends_at,'[)') && tstzrange(t.starts_at,t.ends_at,'[)'))
 AND (d.release_at<=clock_timestamp() OR q.slot_limit>(SELECT count(*) FROM appointments a JOIN time_slots x ON x.id=a.slot_id WHERE x.schedule_id=d.id AND a.booking_type=p_type AND a.status<>'cancelled'))
 AND ((p_type='self' AND p_action IS NULL AND s.self_booking_allowed) OR
 EXISTS(SELECT 1 FROM care_actions c JOIN episodes e ON e.id=c.episode_id WHERE c.id=p_action AND c.kind=p_type AND c.status='assigned' AND c.target_specialty_id=s.id AND e.patient_id=p_patient))
 ORDER BY t.starts_at,t.id;
END $$;

CREATE VIEW quota_statistics AS
SELECT d.id schedule_id,d.doctor_id,d.work_date,q.booking_type,q.slot_limit,
 d.release_at<=clock_timestamp() AS released,
 count(a.id) FILTER(WHERE a.status<>'cancelled') AS occupied,
 count(a.id) FILTER(WHERE a.status='held') AS held
FROM doctor_schedules d JOIN daily_quotas q ON q.schedule_id=d.id
LEFT JOIN time_slots t ON t.schedule_id=d.id
LEFT JOIN appointments a ON a.slot_id=t.id AND a.booking_type=q.booking_type
GROUP BY d.id,q.booking_type,q.slot_limit;

REVOKE ALL ON ALL TABLES IN SCHEMA clinic FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA clinic FROM PUBLIC;
REVOKE ALL ON ALL PROCEDURES IN SCHEMA clinic FROM PUBLIC;
-- Grant access to the backend DB role during deployment, after its creation.
-- Never expose the database owner's credentials to patient clients.
