# AnyHack

Мультитул для рутованного Android (Xiaomi 14T / HyperOS, KernelSU):

- **Dashboard** — мониторинг CPU / GPU Mali-G615 / ОЗУ / диска / температур
  через фоновую root-сессию `su` (опрос раз в 1.5 с).
- **Display** — лок герцовки: Auto / 60 / 90 / 120 / 144 Гц через
  `settings put system user_refresh_rate|miui_refresh_rate|min_refresh_rate|peak_refresh_rate`.
- **Other** — ИК-пульт: импорт `.ir`-файлов Flipper Zero (raw + parsed
  NEC / NECext / Samsung32 / SIRC / RC5 / RC6), трансляция через
  `ConsumerIrManager` (MethodChannel `com.anyhack.app/ir`).

## Сборка

CI: GitHub Actions (`.github/workflows/release.yml`) собирает
`AnyHack-arm64.apk` и публикует в GitHub Releases при пуше в `main`.
