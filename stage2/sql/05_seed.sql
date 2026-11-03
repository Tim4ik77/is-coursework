\set ON_ERROR_STOP on
BEGIN;
SET search_path=clinic,public;
SET TIME ZONE 'Europe/Moscow';
-- Fictional data only. Hash placeholders cannot be used for real authentication.
INSERT INTO users(login,password_hash,role) VALUES
 ('admin','DEMO_ONLY_NOT_A_VALID_PASSWORD_HASH','admin'),
 ('doctor1','DEMO_ONLY_NOT_A_VALID_PASSWORD_HASH','doctor'),
 ('doctor2','DEMO_ONLY_NOT_A_VALID_PASSWORD_HASH','doctor'),
 ('registrar','DEMO_ONLY_NOT_A_VALID_PASSWORD_HASH','registrar');
INSERT INTO doctors(user_id,full_name) VALUES(2,'Учебный Терапевт'),(3,'Учебный Кардиолог');
SELECT register_patient('patient'||g,'DEMO_ONLY_NOT_A_VALID_PASSWORD_HASH','Вымышленный Пациент '||g,date '1990-01-01'+g,lpad(g::text,16,'0')) FROM generate_series(1,12) g;
INSERT INTO specialties(name,self_booking_allowed) VALUES('Терапия',true),('Кардиология',false);
INSERT INTO doctor_specialties VALUES(1,1),(2,2),(2,1);
INSERT INTO doctor_schedules(doctor_id,specialty_id,work_date,start_time,end_time,slot_minutes,release_at)
 VALUES(1,1,current_date+7,'09:00','12:00',30,(current_date+6)::timestamptz),
       (2,2,current_date+7,'09:00','12:00',30,(current_date+6)::timestamptz);
INSERT INTO schedule_breaks(schedule_id,start_time,end_time) VALUES(1,'10:00','10:30'),(2,'10:00','10:30');
CALL generate_slots(1); CALL generate_slots(2);
INSERT INTO daily_quotas VALUES(1,'self',3),(1,'referral',1),(1,'followup',1),(2,'self',0),(2,'referral',4),(2,'followup',1);
INSERT INTO episodes(patient_id,title) VALUES(1,'Учебный эпизод 1'),(2,'Учебный эпизод 2');
INSERT INTO care_actions(episode_id,created_by_doctor_id,target_specialty_id,kind,title)
 VALUES(1,1,2,'referral','Консультация кардиолога'),(1,1,1,'followup','Повторный приём'),(1,1,NULL,'study','Учебное исследование');
SELECT book_appointment(1,1,'self',5);
CALL complete_appointment(1,1,1,'Учебные жалобы','Учебный осмотр','Учебный диагноз','Учебные рекомендации');
INSERT INTO note_addenda(medical_note_id,doctor_id,content) VALUES(1,1,'Учебное уточнение исходной записи');
SELECT book_appointment(1,7,'referral',5,1);
SELECT book_appointment(2,2,'self',6);
INSERT INTO study_results(care_action_id,entered_by_doctor_id,result_text) VALUES(3,1,'Вымышленный результат');
UPDATE care_actions SET status='completed' WHERE id=3;
INSERT INTO questionnaires(doctor_id,version,title) VALUES(1,1,'Базовый опрос');
INSERT INTO questions(questionnaire_id,position,question_text) VALUES(1,1,'Какие жалобы?'),(1,2,'Как давно появились?');
INSERT INTO questionnaire_submissions(appointment_id,questionnaire_id) VALUES(3,1);
INSERT INTO questionnaire_answers VALUES(1,1,1,'Учебный ответ'),(1,2,1,'Вчера');
INSERT INTO waitlist_entries(patient_id,specialty_id,booking_type,preferred_from,preferred_until)
 VALUES(3,1,'self',(current_date+7+time '09:00') AT TIME ZONE 'Europe/Moscow',(current_date+7+time '12:00') AT TIME ZONE 'Europe/Moscow');
SELECT offer_slot(3,1);
COMMIT;
ANALYZE;
