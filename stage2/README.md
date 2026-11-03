# Второй этап: PostgreSQL

24 таблицы, связь M:N «врач — специальность», SQL DDL, триггеры, PL/pgSQL-функции и процедуры, тестовые данные и отчет.

## Быстрый запуск

Проверено на PostgreSQL 18.6. Нужны `psql`, право создания БД и расширение `btree_gist`. Для Helios предварительно проверить доступность расширения и право `CREATEDB`. Если отдельную БД создавать нельзя, установить схему `clinic` в предоставленную пустую БД, заменив имя в командах. Не устанавливать поверх существующей схемы `clinic`.

```sh
psql -X -v ON_ERROR_STOP=1 -d postgres -f stage2/sql/00_create_database.sql
psql -X -v ON_ERROR_STOP=1 -d clinic_coursework -f stage2/sql/install.sql
psql -X -v ON_ERROR_STOP=1 -d clinic_coursework -f stage2/sql/05_seed.sql
psql -X -v ON_ERROR_STOP=1 -d clinic_coursework -f stage2/tests/integrity.sql
psql -X -v ON_ERROR_STOP=1 -d clinic_coursework -f stage2/tests/lifecycle.sql
psql -X -v ON_ERROR_STOP=1 -d clinic_coursework -f stage2/sql/06_explain.sql
```

Параметры подключения: стандартные `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`/`.pgpass`. Пароли в репозитории не сохраняются. Все процедуры вызываются с `SET search_path=clinic,public`; транзакции записи — `READ COMMITTED`.

Windows: `./stage2/run.ps1 -Action create -Psql 'C:/Program Files/PostgreSQL/18/bin/psql.exe'`, затем действия `install`, `seed`, `test`, `explain`.

Проверка конкуренции **изменяет тестовые записи**; запускать последней на свежих тестовых данных:

```sh
PGDATABASE=clinic_coursework python stage2/tests/concurrency.py
```

На Windows задать `$env:PGDATABASE='clinic_coursework'`; при необходимости `$env:PSQL` — путь к `psql.exe`.

Удаление всей учебной БД (данные будут потеряны; активные соединения сначала закрыть):

```sh
psql -X -v ON_ERROR_STOP=1 -d postgres -f stage2/sql/99_drop_database.sql
```

Повторная установка: удалить учебную БД и выполнить создание, установку и заполнение. Скрипты установки и наполнения намеренно не скрывают повторный запуск через `IF NOT EXISTS`/`ON CONFLICT DO NOTHING`.

## Материалы

- `report.md`, `report.docx` — отчет.
- `models/er.md` — концептуальная ER-модель; `models/logical.md` — диаграмма и полный словарь данных из каталога PostgreSQL.
- `models/logical.drawio` — редактируемая физическая схема; `models/source_*.drawio` — исходные пользовательские схемы, сохраненные как источники, не как точная схема текущего SQL.
- `sql/01_schema.sql` — таблицы; `02_integrity.sql` — целостность; `03_routines.sql` — операции; `04_indexes.sql` — индексы.
- `validation.md` — фактически выполненные проверки и ограничения результатов.
- `approval.md` — лист согласования; согласование еще не состоялось.

Планировщик будущего приложения должен регулярно вызывать `expire_holds`, затем `offer_slot` для освободившихся слотов, и `close_inactive_episodes` раз в сутки. Освобождение квот вычисляется по `release_at` при каждой операции и не требует фонового UPDATE. Просмотр доступных слотов — `available_slots`, окончательная проверка — в транзакции бронирования.

Учебные данные вымышлены; строки `DEMO_ONLY_NOT_A_VALID_PASSWORD_HASH` — заглушки, а не рабочие пароли. Авторизация и хеширование паролей относятся к будущему backend.
