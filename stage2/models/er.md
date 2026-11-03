# Концептуальная ER-модель

Модель отражает поликлинику из финального отчета этапа 1. Сущности имеют независимый смысл; справочники, ассоциации и технические сущности выделены отдельно. Всего в реализации 24 таблицы, в том числе 20 основных предметных сущностей; требование не менее 10 выполнено без учета настроек и журнала.

```mermaid
erDiagram
    USER ||--o| PATIENT : has_profile
    USER ||--o| DOCTOR : has_profile
    DOCTOR }o--o{ SPECIALTY : qualified_in
    DOCTOR ||--o{ SCHEDULE : works
    SPECIALTY ||--o{ SCHEDULE : receives_as
    SCHEDULE ||--o{ BREAK : excludes
    SCHEDULE ||--o{ SLOT : contains
    SCHEDULE ||--|{ QUOTA : limits
    PATIENT ||--o{ APPOINTMENT : books
    SLOT ||--o{ APPOINTMENT : history
    PATIENT ||--o{ WAITLIST_ENTRY : waits
    SPECIALTY ||--o{ WAITLIST_ENTRY : requested
    WAITLIST_ENTRY ||--o{ HOLD : receives
    APPOINTMENT ||--o| HOLD : reservation_details
    PATIENT ||--o{ EPISODE : has
    EPISODE o|--o{ APPOINTMENT : groups
    EPISODE ||--o{ CARE_ACTION : plans
    CARE_ACTION o|--o{ APPOINTMENT : authorizes
    CARE_ACTION o|--o{ WAITLIST_ENTRY : authorizes
    DOCTOR ||--o{ CARE_ACTION : prescribes
    SPECIALTY o|--o{ CARE_ACTION : target
    CARE_ACTION ||--o{ STUDY_RESULT : receives
    DOCTOR ||--o{ STUDY_RESULT : enters
    APPOINTMENT ||--o| MEDICAL_NOTE : records
    DOCTOR ||--o{ MEDICAL_NOTE : authors
    MEDICAL_NOTE ||--o{ ADDENDUM : corrected_by
    DOCTOR ||--o{ ADDENDUM : authors
    DOCTOR ||--o{ QUESTIONNAIRE : publishes
    QUESTIONNAIRE ||--o{ QUESTION : contains
    QUESTIONNAIRE ||--o{ SUBMISSION : filled_as
    APPOINTMENT ||--o| SUBMISSION : has
    SUBMISSION ||--o{ ANSWER : contains
    QUESTION ||--o{ ANSWER : answered
    USER ||--o{ NOTIFICATION : receives
    USER ||--o{ APPOINTMENT : creates
```

Кардинальность `o|` означает 0..1, `||` — ровно 1, `o{` — 0..N, `|{` — 1..N.
Связь врачей и специальностей — **M:N**, реализуется ассоциативной таблицей `doctor_specialties` с составным первичным ключом.
Каждый рабочий день имеет ровно три квоты; это дополнительное ограничение поверх 1:N.
У слота может быть много записей в истории отмен, но не более одной неотмененной записи, включая резерв.
Направление является мероприятием вида `referral`, повторный приём — `followup`, исследование — `study`.
Для самостоятельной записи эпизод необязателен до завершения приёма, для направления и повтора обязателен сразу.

Основные атрибуты и ключи приведены в [даталогической модели](logical.md); исходные пользовательские диаграммы сохранены в `source_clinic.drawio` и `source_ER.drawio`.
`audit_log` и `system_settings` — технические сущности, они не участвуют в диаграмме клинических отношений. У аудитора хранится имя роли БД; персональный пользовательский аудит будет добавлен при интеграции с серверной аутентификацией.
