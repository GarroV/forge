---
# Дефолты системы Forge. НЕ редактировать под себя — переопределения в ~/.claude/forge/profile.md
models:
  intake: fable
  brainstorm: fable
  spec: fable
  research_search: sonnet
  research_synthesis: fable
  dispatcher: opus
  block_agent: opus
  executor: sonnet
converge_limit: 3
test_platform: local
telegram: off
question_batching: true
---
# Конфиг Forge (дефолты)
Каждый ключ выше можно переопределить в профиле пользователя. Скиллы читают: профиль → дефолты.
