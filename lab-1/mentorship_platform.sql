-- Mentorship Platform

-- Чистый старт
DROP SCHEMA IF EXISTS mentorship_platform CASCADE;
CREATE SCHEMA mentorship_platform;
SET search_path TO mentorship_platform;

-- 1) Пользователи
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

-- 2) Навыки (справочник)
CREATE TABLE skills (
  skill_id   SMALLSERIAL PRIMARY KEY,
  name       VARCHAR(80)  NOT NULL UNIQUE,
  category   VARCHAR(80),
  is_active  BOOLEAN      NOT NULL DEFAULT TRUE
);

-- 3) Навыки пользователей (связь M:N)
CREATE TABLE user_skills (
  user_id     BIGINT    NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  skill_id    SMALLINT  NOT NULL REFERENCES skills(skill_id) ON DELETE RESTRICT,
  level       SMALLINT  NOT NULL,   -- 1..5
  years_exp   SMALLINT,
  created_at  TIMESTAMP NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, skill_id),
  CONSTRAINT ck_user_skills_level CHECK (level BETWEEN 1 AND 5),
  CONSTRAINT ck_user_skills_years CHECK (years_exp IS NULL OR years_exp BETWEEN 0 AND 80)
);

-- Индексы на FK (ускоряют JOIN/фильтры)
CREATE INDEX idx_user_skills_user   ON user_skills(user_id);
CREATE INDEX idx_user_skills_skill  ON user_skills(skill_id);

-- 4) Предложения менторов (по конкретному навыку)
CREATE TABLE mentor_offers (
  offer_id     BIGSERIAL PRIMARY KEY,
  mentor_id    BIGINT    NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  skill_id     SMALLINT  NOT NULL REFERENCES skills(skill_id) ON DELETE RESTRICT,
  hourly_rate  NUMERIC(10,2) NOT NULL CHECK (hourly_rate >= 0),
  currency     CHAR(3)   NOT NULL,
  format       VARCHAR(30) NOT NULL,       -- online/offline/mixed
  language     VARCHAR(30),
  note         VARCHAR(400),
  status       VARCHAR(20) NOT NULL DEFAULT 'active', -- active/paused/archived
  created_at   TIMESTAMP   NOT NULL DEFAULT now(),
  updated_at   TIMESTAMP
);

CREATE INDEX idx_offer_mentor ON mentor_offers(mentor_id);
CREATE INDEX idx_offer_skill  ON mentor_offers(skill_id);
CREATE INDEX idx_offer_skill_rate ON mentor_offers(skill_id, hourly_rate);

-- 5) Бронирования (заявки менти на оффер)
CREATE TABLE bookings (
  booking_id   BIGSERIAL PRIMARY KEY,
  offer_id     BIGINT    NOT NULL REFERENCES mentor_offers(offer_id) ON DELETE CASCADE,
  mentee_id    BIGINT    NOT NULL REFERENCES users(user_id)         ON DELETE CASCADE,
  starts_at    TIMESTAMP NOT NULL,
  ends_at      TIMESTAMP NOT NULL,
  status       VARCHAR(20) NOT NULL DEFAULT 'pending', -- pending/approved/rejected/cancelled/completed/no_show
  price_total  NUMERIC(10,2),
  currency     CHAR(3),
  created_at   TIMESTAMP NOT NULL DEFAULT now(),
  updated_at   TIMESTAMP,
  CONSTRAINT ck_booking_time CHECK (ends_at > starts_at)
);

CREATE INDEX idx_booking_offer   ON bookings(offer_id);
CREATE INDEX idx_booking_mentee  ON bookings(mentee_id);
CREATE INDEX idx_booking_status  ON bookings(status);

-- 6) Сессии (факт проведения; 1:1 с booking)
CREATE TABLE sessions (
  session_id         BIGSERIAL PRIMARY KEY,
  booking_id         BIGINT    NOT NULL UNIQUE REFERENCES bookings(booking_id) ON DELETE CASCADE,
  actual_started_at  TIMESTAMP,
  actual_ended_at    TIMESTAMP,
  duration_min       INTEGER,
  status             VARCHAR(20) NOT NULL DEFAULT 'completed', -- completed/cancelled/no_show/disputed
  created_at         TIMESTAMP   NOT NULL DEFAULT now(),
  updated_at         TIMESTAMP,
  CONSTRAINT ck_session_time CHECK (
    actual_ended_at IS NULL OR actual_started_at IS NULL OR actual_ended_at > actual_started_at
  ),
  CONSTRAINT ck_session_duration CHECK (duration_min IS NULL OR duration_min >= 0)
);

-- 7) Отзывы/оценки по сессиям
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

-- 8) Сообщения в рамках бронирования (чат)
CREATE TABLE messages (
  message_id BIGSERIAL PRIMARY KEY,
  booking_id BIGINT   NOT NULL REFERENCES bookings(booking_id) ON DELETE CASCADE,
  author_id  BIGINT   NOT NULL REFERENCES users(user_id)       ON DELETE CASCADE,
  body       VARCHAR(5000) NOT NULL,
  created_at TIMESTAMP     NOT NULL DEFAULT now()
);

CREATE INDEX idx_messages_booking ON messages(booking_id);
CREATE INDEX idx_messages_author  ON messages(author_id);

-- Гарантируем последовательный поисковый путь
SELECT 'Schema mentorship_platform is ready.' AS info;
