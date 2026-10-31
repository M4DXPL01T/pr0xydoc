<div align="center">

<img src="docs/logo.png" alt="ListMeUp" width="80" />

# ListMeUp

**Платформа онлайн-записи для сервисного бизнеса**

Салоны красоты · Барбершопы · Стоматологии · Массажные кабинеты · Фитнес-студии

[![Stack](https://img.shields.io/badge/Stack-React_+_FastAPI_+_PostgreSQL-0097A7?style=flat-square)](#tech-stack)
[![i18n](https://img.shields.io/badge/Languages-RU_|_EN_|_ZH-26C6DA?style=flat-square)](#features)
[![License](https://img.shields.io/badge/License-Proprietary-red?style=flat-square)](#license)

</div>

---

## О проекте

**ListMeUp** — SaaS-платформа для управления записями клиентов. Владелец бизнеса настраивает услуги, команду и расписание — получает ссылку, по которой клиенты записываются самостоятельно. Без регистрации, без приложения.

Разработан как полноценная альтернатива YCLIENTS, Dikidi, Booksy — с фокусом на простоту, скорость и современный дизайн.

---

## Скриншоты

<div align="center">

### Публичная страница записи
<img src="docs/screenshots/price.png" alt="Booking page" width="700" />

<br/><br/>

### Календарь записей
<img src="docs/screenshots/calendar.png" alt="Calendar" width="700" />

<br/><br/>

### Статистика и аналитика
<img src="docs/screenshots/stats.png" alt="Statistics" width="700" />

<br/><br/>

### Клиентская база
<img src="docs/screenshots/clients.png" alt="Clients" width="700" />

<br/><br/>

### Управление командой
<img src="docs/screenshots/team.png" alt="Team" width="700" />

</div>

---

## Возможности

### Для владельца бизнеса
- **Услуги и цены** — фиксированная, «от», договорная. Индивидуальные цены для каждого сотрудника
- **Команда** — персональное расписание, отпуска, привязка услуг
- **Календарь** — все записи на одном экране. Статусы: в работе, завершена, отменена
- **Статус сотрудников** — кто свободен прямо сейчас, кто занят до какого времени
- **Клиентская база** — история визитов, фильтры по давности и услугам, бейджи неактивности
- **Статистика** — выручка (только завершённые), топ услуг, загрузка по дням, новые/уникальные клиенты
- **Гибкие настройки** — часовой пояс, валюта, рабочие часы, минимальное время до записи

### Для клиента
- **Запись без регистрации** — выбрал услугу → специалиста → время → готово
- **Управление записью** — перенос, отмена по ссылке
- **Предупреждение о цене** — если у специалиста цена отличается от прайса
- **Фильтрация слотов** — только свободное время, прошедшие слоты скрыты
- **Мультиязычность** — интерфейс на русском, английском и китайском

### Техническое
- **Валидация** — минимальное время до записи, рабочие часы, отпуска, пересечения
- **Ошибки на 3 языках** — 13 кодов ошибок с i18n
- **Тёмная тема** — полная поддержка dark mode
- **Адаптивность** — мобильные телефоны, планшеты, десктоп
- **Безопасность** — JWT access/refresh токены, смена пароля, восстановление по email

---

## Tech Stack

| Слой | Технологии |
|------|-----------|
| **Frontend** | React 18, TypeScript, Tailwind CSS, TanStack Query, React Router |
| **Backend** | Python 3.13, FastAPI, SQLAlchemy 2.0, Alembic |
| **Database** | PostgreSQL 16 |
| **Infra** | Docker, Docker Compose, Nginx |
| **Email** | Resend (transactional emails) |
| **Bot** | Telegram Bot API (уведомления, webhook) |
| **i18n** | Custom lightweight i18n (RU / EN / ZH) |

---

## Архитектура

```
┌─────────────────────────────────────────────────────┐
│                    Nginx (reverse proxy)             │
├──────────────────────┬──────────────────────────────┤
│   React SPA (Vite)   │   FastAPI (Uvicorn)          │
│   /app/*             │   /api/*                     │
│   /b/:slug           │   /api/auth/*                │
│                      │   /api/appointments/*        │
│                      │   /api/services/*            │
│                      │   /api/resources/*           │
│                      │   /api/clients/*             │
│                      │   /api/stats/*               │
│                      │   /api/public/:slug/*        │
│                      │   /api/telegram/webhook      │
├──────────────────────┴──────────────────────────────┤
│                  PostgreSQL 16                       │
└─────────────────────────────────────────────────────┘
```

### Структура проекта

```
listmeup/
├── apps/
│   ├── api/                  # FastAPI backend
│   │   ├── app/
│   │   │   ├── core/         # Config, DB, auth, email, telegram
│   │   │   ├── models/       # SQLAlchemy models
│   │   │   ├── routers/      # API endpoints
│   │   │   └── main.py       # App entry point
│   │   ├── migrations/       # Alembic migrations
│   │   └── requirements.txt
│   └── web/                  # React frontend
│       ├── src/
│       │   ├── app/          # Auth, layout, routing
│       │   ├── i18n/         # Translations (ru/en/zh)
│       │   ├── pages/        # Pages (app + public)
│       │   └── shared/       # API client, components
│       └── package.json
└── infra/                    # Docker, Nginx configs
```

---

## Ключевые решения

- **Цена фиксируется при записи** (`price_final_cents`) — корректная выручка даже если цены менялись
- **Override цен по сотруднику** — один маникюр стоит по-разному у разных мастеров
- **Слоты генерируются на лету** — учитывают расписание, отпуска, буферы, существующие записи
- **"Любой специалист"** — система подбирает первого свободного, предупреждает если цена отличается
- **Клиентская база без регистрации** — агрегация по телефону из записей
- **Выручка считает только завершённые** — записи со статусом booked + end_at в прошлом

---

## Статус

🚀 **Pre-launch** — продукт готов к деплою. В работе: Telegram-уведомления, подтверждение email, интеграция с платёжными системами.

---

## Автор

Разработано с нуля — архитектура, бэкенд, фронтенд, деплой.

---

## License

Proprietary. Код закрыт. Данный репозиторий — витрина проекта.
