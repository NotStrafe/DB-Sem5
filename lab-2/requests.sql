-- =====================================================================================
-- Лабораторная работа 2. Mentorship Platform
-- =====================================================================================

-- 1. Создание схемы и таблиц (DDL)
DROP SCHEMA IF EXISTS mentorship_platform CASCADE;
CREATE SCHEMA mentorship_platform;
SET search_path TO mentorship_platform;

-- Пользователи платформы
CREATE TABLE users (
  user_id        BIGSERIAL PRIMARY KEY,
  username       VARCHAR(50)  NOT NULL UNIQUE,
  full_name      VARCHAR(120),
  email          VARCHAR(100) NOT NULL UNIQUE,
  password_hash  VARCHAR(200) NOT NULL,
  country        VARCHAR(100),
  city           VARCHAR(100),
  timezone       VARCHAR(50),
  is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMP    NOT NULL DEFAULT now(),
  updated_at     TIMESTAMP
);

-- Справочник навыков
CREATE TABLE skills (
  skill_id   SMALLSERIAL PRIMARY KEY,
  name       VARCHAR(80)  NOT NULL UNIQUE,
  category   VARCHAR(80),
  is_active  BOOLEAN      NOT NULL DEFAULT TRUE
);

-- Навыки пользователей
CREATE TABLE user_skills (
  user_id     BIGINT    NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  skill_id    SMALLINT  NOT NULL REFERENCES skills(skill_id) ON DELETE RESTRICT,
  level       SMALLINT  NOT NULL,
  years_exp   SMALLINT,
  created_at  TIMESTAMP NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, skill_id),
  CONSTRAINT ck_user_skills_level CHECK (level BETWEEN 1 AND 5),
  CONSTRAINT ck_user_skills_years CHECK (years_exp IS NULL OR years_exp BETWEEN 0 AND 80)
);

CREATE INDEX idx_user_skills_user  ON user_skills(user_id);
CREATE INDEX idx_user_skills_skill ON user_skills(skill_id);

-- Публичные офферы менторов по конкретному навыку
CREATE TABLE mentor_offers (
  offer_id     BIGSERIAL PRIMARY KEY,
  mentor_id    BIGINT    NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  skill_id     SMALLINT  NOT NULL REFERENCES skills(skill_id) ON DELETE RESTRICT,
  hourly_rate  NUMERIC(10,2) NOT NULL CHECK (hourly_rate >= 0),
  currency     CHAR(3)   NOT NULL,
  format       VARCHAR(30) NOT NULL,
  language     VARCHAR(30),
  note         VARCHAR(400),
  status       VARCHAR(20) NOT NULL DEFAULT 'active',
  created_at   TIMESTAMP   NOT NULL DEFAULT now(),
  updated_at   TIMESTAMP
);

CREATE INDEX idx_offer_mentor        ON mentor_offers(mentor_id);
CREATE INDEX idx_offer_skill         ON mentor_offers(skill_id);
CREATE INDEX idx_offer_skill_rate    ON mentor_offers(skill_id, hourly_rate);

-- Бронирования (заявки менти на консультации)
CREATE TABLE bookings (
  booking_id   BIGSERIAL PRIMARY KEY,
  offer_id     BIGINT    NOT NULL REFERENCES mentor_offers(offer_id) ON DELETE CASCADE,
  mentee_id    BIGINT    NOT NULL REFERENCES users(user_id)         ON DELETE CASCADE,
  starts_at    TIMESTAMP NOT NULL,
  ends_at      TIMESTAMP NOT NULL,
  status       VARCHAR(20) NOT NULL DEFAULT 'pending',
  price_total  NUMERIC(10,2),
  currency     CHAR(3),
  created_at   TIMESTAMP NOT NULL DEFAULT now(),
  updated_at   TIMESTAMP,
  CONSTRAINT ck_booking_time CHECK (ends_at > starts_at)
);

CREATE INDEX idx_booking_offer   ON bookings(offer_id);
CREATE INDEX idx_booking_mentee  ON bookings(mentee_id);
CREATE INDEX idx_booking_status  ON bookings(status);

-- Фактические сессии
CREATE TABLE sessions (
  session_id         BIGSERIAL PRIMARY KEY,
  booking_id         BIGINT    NOT NULL UNIQUE REFERENCES bookings(booking_id) ON DELETE CASCADE,
  actual_started_at  TIMESTAMP,
  actual_ended_at    TIMESTAMP,
  duration_min       INTEGER,
  status             VARCHAR(20) NOT NULL DEFAULT 'completed',
  created_at         TIMESTAMP   NOT NULL DEFAULT now(),
  updated_at         TIMESTAMP,
  CONSTRAINT ck_session_time CHECK (
    actual_ended_at IS NULL OR actual_started_at IS NULL OR actual_ended_at > actual_started_at
  ),
  CONSTRAINT ck_session_duration CHECK (duration_min IS NULL OR duration_min >= 0)
);

-- Отзывы по сессиям
CREATE TABLE session_feedbacks (
  feedback_id  BIGSERIAL PRIMARY KEY,
  session_id   BIGINT   NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
  author_id    BIGINT   NOT NULL REFERENCES users(user_id)      ON DELETE CASCADE,
  target_id    BIGINT   NOT NULL REFERENCES users(user_id)      ON DELETE CASCADE,
  rating       SMALLINT NOT NULL,
  comment      VARCHAR(1000),
  created_at   TIMESTAMP NOT NULL DEFAULT now(),
  CONSTRAINT ck_feedback_rating CHECK (rating BETWEEN 1 AND 5),
  CONSTRAINT uq_feedback_once UNIQUE (session_id, author_id)
);

CREATE INDEX idx_feedback_target ON session_feedbacks(target_id);

-- Сообщения в рамках бронирований
CREATE TABLE messages (
  message_id BIGSERIAL PRIMARY KEY,
  booking_id BIGINT   NOT NULL REFERENCES bookings(booking_id) ON DELETE CASCADE,
  author_id  BIGINT   NOT NULL REFERENCES users(user_id)       ON DELETE CASCADE,
  body       VARCHAR(5000) NOT NULL,
  created_at TIMESTAMP     NOT NULL DEFAULT now()
);

CREATE INDEX idx_messages_booking ON messages(booking_id);
CREATE INDEX idx_messages_author  ON messages(author_id);

-- 2. Наполнение базы данными (INSERT)

-- Пользователи
INSERT INTO users
  (username, full_name, email, password_hash, country, city, timezone, is_active, created_at)
VALUES
  ('mentor_anna',  'Anna Petrova',     'anna@example.com',    'hash_anna',  'Russia',   'Moscow',      'UTC+3', TRUE,  '2023-12-01 10:00'),
  ('mentor_ivan',  'Ivan Korolev',     'ivan@example.com',    'hash_ivan',  'Russia',   'Saint-Petersburg', 'UTC+3', TRUE,  '2023-12-02 11:20'),
  ('mentor_lucas', 'Lucas Meyer',      'lucas@example.com',   'hash_lucas', 'Germany',  'Berlin',      'UTC+1', TRUE,  '2023-12-05 09:10'),
  ('mentee_alex',  'Alex Kim',         'alex@example.com',    'hash_alex',  'USA',      'Austin',      'UTC-6', TRUE,  '2024-01-02 15:00'),
  ('mentee_daria', 'Daria Voronina',   'daria@example.com',   'hash_daria', 'Kazakhstan','Almaty',     'UTC+6', TRUE,  '2024-01-03 18:20'),
  ('mentee_yuki',  'Yuki Tanaka',      'yuki@example.com',    'hash_yuki',  'Japan',    'Tokyo',       'UTC+9', TRUE,  '2024-01-05 08:30');

-- Навыки
INSERT INTO skills (name, category, is_active) VALUES
  ('Python Backend',    'Software Engineering', TRUE),
  ('Data Science',      'Analytics',            TRUE),
  ('Product Management','Management',           TRUE),
  ('DevOps',            'Infrastructure',       TRUE),
  ('Career Coaching',   'Soft Skills',          TRUE);

-- Навыки пользователей
INSERT INTO user_skills (user_id, skill_id, level, years_exp)
SELECT u.user_id, s.skill_id, 5, 7
FROM users u
JOIN skills s ON s.name = 'Python Backend'
WHERE u.username = 'mentor_anna'
UNION ALL
SELECT u.user_id, s.skill_id, 4, 5
FROM users u
JOIN skills s ON s.name = 'Data Science'
WHERE u.username = 'mentor_anna'
UNION ALL
SELECT u.user_id, s.skill_id, 5, 8
FROM users u
JOIN skills s ON s.name = 'DevOps'
WHERE u.username = 'mentor_ivan'
UNION ALL
SELECT u.user_id, s.skill_id, 3, 3
FROM users u
JOIN skills s ON s.name = 'Career Coaching'
WHERE u.username = 'mentor_ivan'
UNION ALL
SELECT u.user_id, s.skill_id, 5, 10
FROM users u
JOIN skills s ON s.name = 'Product Management'
WHERE u.username = 'mentor_lucas'
UNION ALL
SELECT u.user_id, s.skill_id, 4, 7
FROM users u
JOIN skills s ON s.name = 'Career Coaching'
WHERE u.username = 'mentor_lucas'
UNION ALL
SELECT u.user_id, s.skill_id, 2, 1
FROM users u
JOIN skills s ON s.name = 'Python Backend'
WHERE u.username = 'mentee_alex'
UNION ALL
SELECT u.user_id, s.skill_id, 3, 2
FROM users u
JOIN skills s ON s.name = 'Product Management'
WHERE u.username = 'mentee_alex'
UNION ALL
SELECT u.user_id, s.skill_id, 1, 0
FROM users u
JOIN skills s ON s.name = 'Data Science'
WHERE u.username = 'mentee_daria'
UNION ALL
SELECT u.user_id, s.skill_id, 2, 1
FROM users u
JOIN skills s ON s.name = 'DevOps'
WHERE u.username = 'mentee_yuki';

-- Публичные офферы
INSERT INTO mentor_offers
  (mentor_id, skill_id, hourly_rate, currency, format, language, note, status, created_at)
SELECT u.user_id, s.skill_id, 80.00, 'USD', 'online', 'EN', 'Python backend for web services', 'active', '2024-01-04 12:00'
FROM users u
JOIN skills s ON s.name = 'Python Backend'
WHERE u.username = 'mentor_anna'
UNION ALL
SELECT u.user_id, s.skill_id, 95.00, 'USD', 'online', 'EN', 'ML pipelines and metrics review', 'active', '2024-01-06 09:30'
FROM users u
JOIN skills s ON s.name = 'Data Science'
WHERE u.username = 'mentor_anna'
UNION ALL
SELECT u.user_id, s.skill_id, 70.00, 'EUR', 'mixed', 'EN', 'DevOps culture and tooling', 'active', '2024-01-08 14:00'
FROM users u
JOIN skills s ON s.name = 'DevOps'
WHERE u.username = 'mentor_ivan'
UNION ALL
SELECT u.user_id, s.skill_id, 85.00, 'EUR', 'online', 'EN', 'Product strategy deep dives', 'active', '2024-01-09 16:00'
FROM users u
JOIN skills s ON s.name = 'Product Management'
WHERE u.username = 'mentor_lucas'
UNION ALL
SELECT u.user_id, s.skill_id, 60.00, 'EUR', 'online', 'EN', 'Career pivots and leadership', 'paused', '2024-01-11 10:45'
FROM users u
JOIN skills s ON s.name = 'Career Coaching'
WHERE u.username = 'mentor_lucas';

-- Бронирования
INSERT INTO bookings
  (offer_id, mentee_id, starts_at, ends_at, status, price_total, currency, created_at)
SELECT o.offer_id, mentee.user_id, TIMESTAMP '2024-01-10 09:00', TIMESTAMP '2024-01-10 10:30',
       'completed', 120.00, o.currency, '2024-01-05 10:00'
FROM mentor_offers o
JOIN users mentor ON mentor.user_id = o.mentor_id
JOIN users mentee ON mentee.username = 'mentee_alex'
JOIN skills s ON s.skill_id = o.skill_id
WHERE mentor.username = 'mentor_anna' AND s.name = 'Python Backend'
UNION ALL
SELECT o.offer_id, mentee.user_id, TIMESTAMP '2024-02-05 18:00', TIMESTAMP '2024-02-05 19:00',
       'approved', 95.00, o.currency, '2024-01-22 12:10'
FROM mentor_offers o
JOIN users mentor ON mentor.user_id = o.mentor_id
JOIN users mentee ON mentee.username = 'mentee_daria'
JOIN skills s ON s.skill_id = o.skill_id
WHERE mentor.username = 'mentor_anna' AND s.name = 'Data Science'
UNION ALL
SELECT o.offer_id, mentee.user_id, TIMESTAMP '2024-02-12 11:00', TIMESTAMP '2024-02-12 12:30',
       'completed', 105.00, o.currency, '2024-01-25 15:40'
FROM mentor_offers o
JOIN users mentor ON mentor.user_id = o.mentor_id
JOIN users mentee ON mentee.username = 'mentee_yuki'
JOIN skills s ON s.skill_id = o.skill_id
WHERE mentor.username = 'mentor_ivan' AND s.name = 'DevOps'
UNION ALL
SELECT o.offer_id, mentee.user_id, TIMESTAMP '2024-03-03 15:00', TIMESTAMP '2024-03-03 16:00',
       'pending', 85.00, o.currency, '2024-02-15 09:05'
FROM mentor_offers o
JOIN users mentor ON mentor.user_id = o.mentor_id
JOIN users mentee ON mentee.username = 'mentee_alex'
JOIN skills s ON s.skill_id = o.skill_id
WHERE mentor.username = 'mentor_lucas' AND s.name = 'Product Management'
UNION ALL
SELECT o.offer_id, mentee.user_id, TIMESTAMP '2024-03-07 08:00', TIMESTAMP '2024-03-07 09:30',
       'cancelled', 90.00, o.currency, '2024-02-20 10:15'
FROM mentor_offers o
JOIN users mentor ON mentor.user_id = o.mentor_id
JOIN users mentee ON mentee.username = 'mentee_daria'
JOIN skills s ON s.skill_id = o.skill_id
WHERE mentor.username = 'mentor_lucas' AND s.name = 'Career Coaching';

-- Сессии
INSERT INTO sessions
  (booking_id, actual_started_at, actual_ended_at, duration_min, status, created_at)
SELECT b.booking_id, TIMESTAMP '2024-01-10 09:05', TIMESTAMP '2024-01-10 10:32', 87, 'completed', '2024-01-10 10:35'
FROM bookings b
JOIN users mentee ON mentee.user_id = b.mentee_id
WHERE mentee.username = 'mentee_alex' AND b.starts_at = TIMESTAMP '2024-01-10 09:00'
UNION ALL
SELECT b.booking_id, TIMESTAMP '2024-02-12 11:05', TIMESTAMP '2024-02-12 12:20', 75, 'completed', '2024-02-12 12:30'
FROM bookings b
JOIN users mentee ON mentee.user_id = b.mentee_id
WHERE mentee.username = 'mentee_yuki' AND b.starts_at = TIMESTAMP '2024-02-12 11:00'
UNION ALL
SELECT b.booking_id, TIMESTAMP '2024-03-07 08:00', TIMESTAMP '2024-03-07 08:05', 5, 'cancelled', '2024-03-07 08:05'
FROM bookings b
JOIN users mentee ON mentee.user_id = b.mentee_id
WHERE mentee.username = 'mentee_daria' AND b.starts_at = TIMESTAMP '2024-03-07 08:00';

-- Отзывы
INSERT INTO session_feedbacks
  (session_id, author_id, target_id, rating, comment, created_at)
SELECT s.session_id, mentee.user_id, mentor.user_id, 5, 'Отличный код-ревью и рекомендации.', '2024-01-10 12:00'
FROM sessions s
JOIN bookings b ON b.booking_id = s.booking_id
JOIN mentor_offers o ON o.offer_id = b.offer_id
JOIN users mentor ON mentor.user_id = o.mentor_id
JOIN users mentee ON mentee.user_id = b.mentee_id
WHERE mentee.username = 'mentee_alex' AND b.starts_at = TIMESTAMP '2024-01-10 09:00'
UNION ALL
SELECT s.session_id, mentor.user_id, mentee.user_id, 4, 'Домашнее задание выполнено хорошо.', '2024-01-10 12:10'
FROM sessions s
JOIN bookings b ON b.booking_id = s.booking_id
JOIN mentor_offers o ON o.offer_id = b.offer_id
JOIN users mentor ON mentor.user_id = o.mentor_id
JOIN users mentee ON mentee.user_id = b.mentee_id
WHERE mentee.username = 'mentee_alex' AND b.starts_at = TIMESTAMP '2024-01-10 09:00'
UNION ALL
SELECT s.session_id, mentee.user_id, mentor.user_id, 5, 'Полезные практики автоматизации.', '2024-02-12 15:00'
FROM sessions s
JOIN bookings b ON b.booking_id = s.booking_id
JOIN mentor_offers o ON o.offer_id = b.offer_id
JOIN users mentor ON mentor.user_id = o.mentor_id
JOIN users mentee ON mentee.user_id = b.mentee_id
WHERE mentee.username = 'mentee_yuki' AND b.starts_at = TIMESTAMP '2024-02-12 11:00';

-- Сообщения
INSERT INTO messages (booking_id, author_id, body, created_at)
SELECT b.booking_id, mentee.user_id, 'Здравствуйте! Хочу обсудить архитектуру.', '2024-01-08 09:00'
FROM bookings b
JOIN users mentee ON mentee.user_id = b.mentee_id
WHERE mentee.username = 'mentee_alex' AND b.starts_at = TIMESTAMP '2024-01-10 09:00'
UNION ALL
SELECT b.booking_id, mentor.user_id, 'Принято, подготовлю материалы.', '2024-01-08 12:00'
FROM bookings b
JOIN mentor_offers o ON o.offer_id = b.offer_id
JOIN users mentor ON mentor.user_id = o.mentor_id
JOIN users mentee ON mentee.user_id = b.mentee_id
WHERE mentee.username = 'mentee_alex' AND b.starts_at = TIMESTAMP '2024-01-10 09:00'
UNION ALL
SELECT b.booking_id, mentee.user_id, 'Можем перенести созвон?', '2024-02-27 08:00'
FROM bookings b
JOIN users mentee ON mentee.user_id = b.mentee_id
WHERE mentee.username = 'mentee_daria' AND b.starts_at = TIMESTAMP '2024-03-07 08:00'
UNION ALL
SELECT b.booking_id, mentor.user_id, 'Боюсь, что придётся отменить.', '2024-02-28 09:15'
FROM bookings b
JOIN mentor_offers o ON o.offer_id = b.offer_id
JOIN users mentor ON mentor.user_id = o.mentor_id
JOIN users mentee ON mentee.user_id = b.mentee_id
WHERE mentee.username = 'mentee_daria' AND b.starts_at = TIMESTAMP '2024-03-07 08:00';

-- 3. Примеры DML-операций

-- 3.1 Вставка новой консультации по карьерному коучингу
INSERT INTO bookings
  (offer_id, mentee_id, starts_at, ends_at, status, price_total, currency, created_at)
SELECT o.offer_id, mentee.user_id, TIMESTAMP '2024-03-15 09:00', TIMESTAMP '2024-03-15 09:45',
       'pending', 45.00, o.currency, now()
FROM mentor_offers o
JOIN users mentor ON mentor.user_id = o.mentor_id
JOIN users mentee ON mentee.username = 'mentee_daria'
JOIN skills s ON s.skill_id = o.skill_id
WHERE mentor.username = 'mentor_lucas' AND s.name = 'Career Coaching'
LIMIT 1;

-- 3.2 Обновление ставки оффера по Data Science у Анны (индексация на 5%)
UPDATE mentor_offers
SET hourly_rate = ROUND(hourly_rate * 1.05, 2),
    updated_at = now()
WHERE offer_id IN (
  SELECT o.offer_id
  FROM mentor_offers o
  JOIN users u ON u.user_id = o.mentor_id
  JOIN skills s ON s.skill_id = o.skill_id
  WHERE u.username = 'mentor_anna' AND s.name = 'Data Science'
);

-- 3.3 Удаление устаревших сообщений по отменённым бронированиям
DELETE FROM messages
WHERE booking_id IN (
    SELECT booking_id FROM bookings WHERE status = 'cancelled'
)
AND created_at < TIMESTAMP '2024-03-01 00:00:00';

-- 4. Запросы с агрегацией

-- 4.1 Доход по каждому ментору и навыку (только завершённые/одобренные консультации)
SELECT mentor.username      AS mentor_username,
       sk.name              AS skill_name,
       SUM(b.price_total)   AS revenue_total,
       COUNT(*)             AS sessions_count
FROM bookings b
JOIN mentor_offers o ON o.offer_id = b.offer_id
JOIN users mentor ON mentor.user_id = o.mentor_id
JOIN skills sk ON sk.skill_id = o.skill_id
WHERE b.status IN ('completed', 'approved')
GROUP BY mentor.username, sk.name
HAVING SUM(b.price_total) > 0
ORDER BY revenue_total DESC;

-- 4.2 Средние рейтинги по менторам
SELECT mentor.username,
       ROUND(AVG(f.rating)::numeric, 2) AS avg_rating,
       COUNT(f.feedback_id)             AS feedbacks_count
FROM session_feedbacks f
JOIN users mentor ON mentor.user_id = f.target_id
GROUP BY mentor.username
ORDER BY avg_rating DESC;

-- 4.3 Количество бронирований по статусам
SELECT status, COUNT(*) AS total
FROM bookings
GROUP BY status
ORDER BY total DESC;

-- 5. Запросы с соединениями

-- 5.1 Ближайшие бронирования с именами ментора, менти и навыком
SELECT b.booking_id,
       mentee.full_name AS mentee_name,
       mentor.full_name AS mentor_name,
       sk.name          AS skill_name,
       b.status,
       b.starts_at
FROM bookings b
JOIN mentor_offers o ON o.offer_id = b.offer_id
JOIN users mentee ON mentee.user_id = b.mentee_id
JOIN users mentor ON mentor.user_id = o.mentor_id
JOIN skills sk ON sk.skill_id = o.skill_id
WHERE b.starts_at >= DATE '2024-01-01'
ORDER BY b.starts_at;

-- 5.2 История переписки по активным бронированиям
SELECT b.booking_id,
       mentee.username AS mentee_username,
       mentor.username AS mentor_username,
       m.body,
       m.created_at
FROM bookings b
JOIN mentor_offers o ON o.offer_id = b.offer_id
JOIN users mentee ON mentee.user_id = b.mentee_id
JOIN users mentor ON mentor.user_id = o.mentor_id
JOIN messages m ON m.booking_id = b.booking_id
WHERE b.status NOT IN ('cancelled')
ORDER BY b.booking_id, m.created_at;

-- 6. Создание представлений

-- 6.1 Представление по эффективности менторов
CREATE OR REPLACE VIEW vw_mentor_performance AS
SELECT mentor.user_id,
       mentor.username,
       mentor.full_name,
       COUNT(DISTINCT b.booking_id) FILTER (WHERE b.status IN ('approved','completed')) AS paid_bookings,
       COALESCE(SUM(b.price_total) FILTER (WHERE b.status IN ('approved','completed')), 0) AS revenue_total,
       ROUND(AVG(f.rating)::numeric, 2) AS avg_rating
FROM users mentor
LEFT JOIN mentor_offers o ON o.mentor_id = mentor.user_id
LEFT JOIN bookings b ON b.offer_id = o.offer_id
LEFT JOIN sessions s ON s.booking_id = b.booking_id
LEFT JOIN session_feedbacks f ON f.session_id = s.session_id AND f.target_id = mentor.user_id
WHERE mentor.username LIKE 'mentor_%'
GROUP BY mentor.user_id, mentor.username, mentor.full_name;

-- 6.2 Представление по ближайшим сессиям (с учётом статусов)
CREATE OR REPLACE VIEW vw_upcoming_sessions AS
SELECT b.booking_id,
       mentee.full_name AS mentee_name,
       mentor.full_name AS mentor_name,
       sk.name          AS skill_name,
       b.starts_at,
       b.status         AS booking_status,
       COALESCE(s.status, 'not_started') AS session_status
FROM bookings b
JOIN mentor_offers o ON o.offer_id = b.offer_id
JOIN users mentee ON mentee.user_id = b.mentee_id
JOIN users mentor ON mentor.user_id = o.mentor_id
JOIN skills sk ON sk.skill_id = o.skill_id
LEFT JOIN sessions s ON s.booking_id = b.booking_id
WHERE b.starts_at >= DATE '2024-01-01';

-- 6.3 Представление по активности в чатах бронирований
CREATE OR REPLACE VIEW vw_booking_messages AS
SELECT b.booking_id,
       mentee.username AS mentee_username,
       mentor.username AS mentor_username,
       COUNT(m.message_id) AS message_count,
       MAX(m.created_at)   AS last_message_at
FROM bookings b
JOIN mentor_offers o ON o.offer_id = b.offer_id
JOIN users mentee ON mentee.user_id = b.mentee_id
JOIN users mentor ON mentor.user_id = o.mentor_id
LEFT JOIN messages m ON m.booking_id = b.booking_id
GROUP BY b.booking_id, mentee.username, mentor.username;

SELECT 'Лабораторная работа 2 завершена.' AS info;
