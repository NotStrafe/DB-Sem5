-- =====================================================================================
-- Лабораторная работа 4. Mentorship Platform — индексы, EXPLAIN и транзакции
-- Допущение: схема mentorship_platform создана и наполнена результатами ЛР1-3.
-- =====================================================================================

SET search_path TO mentorship_platform;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS dblink;

-- =====================================================================================
-- 1. Индексы и анализ производительности
-- =====================================================================================

-- 1.1 Поиск менторов по стране и городу (без индекса)
DROP INDEX IF EXISTS idx_lab4_users_country_city;
EXPLAIN (ANALYZE, COSTS, BUFFERS, VERBOSE)
SELECT user_id, username, country, city
FROM users
WHERE is_active = TRUE AND country = 'USA'
ORDER BY city;

-- Создаём составной индекс и повторяем запрос
CREATE INDEX idx_lab4_users_country_city ON users(country, city) WHERE is_active;
EXPLAIN (ANALYZE, COSTS, BUFFERS, VERBOSE)
SELECT user_id, username, country, city
FROM users
WHERE is_active = TRUE AND country = 'USA'
ORDER BY city;

-- 1.2 Диапазон по сессиям (до индекса)
DROP INDEX IF EXISTS idx_lab4_sessions_started_at;
EXPLAIN (ANALYZE, COSTS, BUFFERS)
SELECT session_id, booking_id, actual_started_at
FROM sessions
WHERE actual_started_at BETWEEN '2024-01-01' AND '2024-06-01'
ORDER BY actual_started_at;

-- Индекс по дате фактического старта
CREATE INDEX idx_lab4_sessions_started_at ON sessions(actual_started_at);
EXPLAIN (ANALYZE, COSTS, BUFFERS)
SELECT session_id, booking_id, actual_started_at
FROM sessions
WHERE actual_started_at BETWEEN '2024-01-01' AND '2024-06-01'
ORDER BY actual_started_at;

-- 1.3 Поиск по подстроке в сообщениях (используем GIN + trigram)
DROP INDEX IF EXISTS idx_lab4_messages_body_trgm;
EXPLAIN (ANALYZE, COSTS, BUFFERS)
SELECT message_id, body
FROM messages
WHERE body ILIKE '%архитектур%';

CREATE INDEX idx_lab4_messages_body_trgm ON messages
USING gin (body gin_trgm_ops);
EXPLAIN (ANALYZE, COSTS, BUFFERS)
SELECT message_id, body
FROM messages
WHERE body ILIKE '%архитектур%';

-- Дополнительный запрос средней сложности с агрегацией после создания индексов
EXPLAIN (ANALYZE, COSTS, BUFFERS)
SELECT mentor.username,
       COUNT(*) FILTER (WHERE b.status = 'completed') AS completed_cnt,
       SUM(b.price_total)                            AS revenue
FROM mentor_offers o
JOIN users mentor ON mentor.user_id = o.mentor_id
LEFT JOIN bookings b ON b.offer_id = o.offer_id
WHERE mentor.country = 'Germany'
GROUP BY mentor.username;

-- =====================================================================================
-- 2. Подготовка тестовой таблицы для демонстрации транзакций
-- =====================================================================================

DROP TABLE IF EXISTS lab4_wallets;
CREATE TABLE lab4_wallets (
  wallet_id  BIGSERIAL PRIMARY KEY,
  mentee_id  BIGINT UNIQUE NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  balance    NUMERIC(10,2) NOT NULL
);

INSERT INTO lab4_wallets (mentee_id, balance)
SELECT user_id, 100.00
FROM users
WHERE username IN ('mentee_alex', 'mentee_daria');

-- Настраиваем вспомогательное соединение dblink для "второй сессии" (T2)
SELECT dblink_connect('lab4_conn', format('dbname=%s', current_database()));
SELECT dblink_exec('lab4_conn', format('SET search_path TO %I;', current_schema()));

-- =====================================================================================
-- 3. Сценарии конкурентного доступа
-- =====================================================================================

-- 3.1 Non-repeatable read под READ COMMITTED и устранение REPEATABLE READ
TRUNCATE lab4_wallets;
INSERT INTO lab4_wallets (mentee_id, balance)
SELECT user_id, 150.00 FROM users WHERE username = 'mentee_alex';

-- Шаги T1
BEGIN;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SELECT 'T1 balance step1' AS info, balance
FROM lab4_wallets w
JOIN users u ON u.user_id = w.mentee_id AND u.username = 'mentee_alex';

-- Шаги T2 через dblink (обновляет баланс)
SELECT dblink_exec('lab4_conn', $$
  BEGIN;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  UPDATE lab4_wallets w
  SET balance = balance + 25
  FROM users u
  WHERE u.user_id = w.mentee_id AND u.username = 'mentee_alex';
  COMMIT;
$$);

-- T1 повторно читает и получает новое значение (неповторяемое чтение)
SELECT 'T1 balance step2' AS info, balance
FROM lab4_wallets w
JOIN users u ON u.user_id = w.mentee_id AND u.username = 'mentee_alex';
COMMIT;

-- Устраняем проблему с REPEATABLE READ
TRUNCATE lab4_wallets;
INSERT INTO lab4_wallets (mentee_id, balance)
SELECT user_id, 150.00 FROM users WHERE username = 'mentee_alex';

BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT 'RR step1' AS info, balance
FROM lab4_wallets w
JOIN users u ON u.user_id = w.mentee_id AND u.username = 'mentee_alex';

SELECT dblink_exec('lab4_conn', $$
  BEGIN;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  UPDATE lab4_wallets w
  SET balance = balance + 25
  FROM users u
  WHERE u.user_id = w.mentee_id AND u.username = 'mentee_alex';
  COMMIT;
$$);

SELECT 'RR step2' AS info, balance
FROM lab4_wallets w
JOIN users u ON u.user_id = w.mentee_id AND u.username = 'mentee_alex';
COMMIT;

-- 3.2 Phantom read под READ COMMITTED и устранение SERIALIZABLE
DROP TABLE IF EXISTS lab4_goals;
CREATE TABLE lab4_goals (
  goal_id     BIGSERIAL PRIMARY KEY,
  mentee_id   BIGINT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  planned_at  DATE   NOT NULL
);

INSERT INTO lab4_goals (mentee_id, planned_at)
SELECT user_id, DATE '2024-04-01'
FROM users
WHERE username = 'mentee_daria';

BEGIN;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SELECT 'T1 count step1' AS info,
       COUNT(*) AS cnt
FROM lab4_goals g
JOIN users u ON u.user_id = g.mentee_id
WHERE u.username = 'mentee_daria' AND planned_at BETWEEN '2024-04-01' AND '2024-04-30';

-- T2 добавляет дополнительную цель (фантом)
SELECT dblink_exec('lab4_conn', $$
  BEGIN;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  INSERT INTO lab4_goals (mentee_id, planned_at)
  SELECT user_id, DATE '2024-04-15' FROM users WHERE username = 'mentee_daria';
  COMMIT;
$$);

SELECT 'T1 count step2' AS info,
       COUNT(*) AS cnt
FROM lab4_goals g
JOIN users u ON u.user_id = g.mentee_id
WHERE u.username = 'mentee_daria' AND planned_at BETWEEN '2024-04-01' AND '2024-04-30';
COMMIT;

-- Устранение фантомов с SERIALIZABLE
TRUNCATE lab4_goals;
INSERT INTO lab4_goals (mentee_id, planned_at)
SELECT user_id, DATE '2024-04-01'
FROM users
WHERE username = 'mentee_daria';

BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SELECT 'SER count step1' AS info,
       COUNT(*) AS cnt
FROM lab4_goals g
JOIN users u ON u.user_id = g.mentee_id
WHERE u.username = 'mentee_daria' AND planned_at BETWEEN '2024-04-01' AND '2024-04-30';

SELECT dblink_exec('lab4_conn', $$
  BEGIN;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  INSERT INTO lab4_goals (mentee_id, planned_at)
  SELECT user_id, DATE '2024-04-15' FROM users WHERE username = 'mentee_daria';
  COMMIT;
$$);

SELECT 'SER count step2' AS info,
       COUNT(*) AS cnt
FROM lab4_goals g
JOIN users u ON u.user_id = g.mentee_id
WHERE u.username = 'mentee_daria' AND planned_at BETWEEN '2024-04-01' AND '2024-04-30';
COMMIT;

-- 3.3 Потерянное обновление (lost update) под READ COMMITTED и предотвращение SERIALIZABLE
TRUNCATE lab4_wallets;
INSERT INTO lab4_wallets (mentee_id, balance)
SELECT user_id, 200.00 FROM users WHERE username = 'mentee_daria';

BEGIN;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SELECT 'T1 initial balance' AS info, balance
FROM lab4_wallets w
JOIN users u ON u.user_id = w.mentee_id AND u.username = 'mentee_daria';

-- T2 читает баланс и запоминает его вне БД (эмуляция клиента)
SELECT dblink_exec('lab4_conn', 'BEGIN;');
SELECT dblink_exec('lab4_conn', 'SET TRANSACTION ISOLATION LEVEL READ COMMITTED;');
SELECT *
FROM dblink('lab4_conn', $$
  SELECT balance FROM lab4_wallets w
  JOIN users u ON u.user_id = w.mentee_id AND u.username = 'mentee_daria'
$$) AS t(balance numeric);

-- T1 применяет свою правку +30
UPDATE lab4_wallets w
SET balance = balance + 30
FROM users u
WHERE u.user_id = w.mentee_id AND u.username = 'mentee_daria';
COMMIT;

-- T2 всё ещё думает, что баланс 200 и устанавливает 170 (потеря обновления)
SELECT dblink_exec('lab4_conn', $$
  UPDATE lab4_wallets w
  SET balance = 170.00
  FROM users u
  WHERE u.user_id = w.mentee_id AND u.username = 'mentee_daria';
  COMMIT;
$$);

SELECT 'Balance after lost update' AS info, balance
FROM lab4_wallets w
JOIN users u ON u.user_id = w.mentee_id AND u.username = 'mentee_daria';

-- Теперь повторим в SERIALIZABLE: T2 получит ошибку сериализации
TRUNCATE lab4_wallets;
INSERT INTO lab4_wallets (mentee_id, balance)
SELECT user_id, 200.00 FROM users WHERE username = 'mentee_daria';

BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SELECT 'T1 serializable start' AS info, balance
FROM lab4_wallets w
JOIN users u ON u.user_id = w.mentee_id AND u.username = 'mentee_daria';

SELECT dblink_exec('lab4_conn', $$
  BEGIN;
  SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
$$);
SELECT *
FROM dblink('lab4_conn', $$
  SELECT balance FROM lab4_wallets w
  JOIN users u ON u.user_id = w.mentee_id AND u.username = 'mentee_daria'
$$) AS t(balance numeric);

UPDATE lab4_wallets w
SET balance = balance + 30
FROM users u
WHERE u.user_id = w.mentee_id AND u.username = 'mentee_daria';
COMMIT;

-- Попытка T2 завершить приводит к ошибке SERIALIZATION_FAILURE
SELECT dblink_exec('lab4_conn', $$
  UPDATE lab4_wallets w
  SET balance = 170.00
  FROM users u
  WHERE u.user_id = w.mentee_id AND u.username = 'mentee_daria';
  COMMIT;
$$) AS t2_result;

SELECT 'Balance after serializable protection' AS info, balance
FROM lab4_wallets w
JOIN users u ON u.user_id = w.mentee_id AND u.username = 'mentee_daria';

SELECT dblink_exec('lab4_conn', 'ROLLBACK;'); -- на случай ошибки сериализации

-- Закрываем dblink-соединение
SELECT dblink_disconnect('lab4_conn');

SELECT 'Лабораторная работа 4 завершена.' AS info;
