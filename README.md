# AnyHack 🔧

мультитул для рутованного **Xiaomi 14T** (HyperOS + KernelSU). три вкладки, ноль балласта, всё живое.

## что внутри

**⚡ Dashboard**
- живой мониторинг каждые 1.5 с (свой интервал в шестерёнке: 0.5 / 1 / custom)
- CPU по ядрам (little / medium / big) + говернор, GPU Mali-G615: частота и нагрузка
- **батарея**: при зарядке — вольты, амперы и ватты снизу, без зарядки — мощность разряда в ваттах
- **профили частот**: `Performance` · `Balanced` · `Economy` · `Economy+` — кап частот ядер одним тапом, запоминается
- ОЗУ, диск `/data`, температуры CPU и GPU

**🖥 Display**
- лок герцовки: Auto / 60 / 90 / 120 / 144 Hz + **Custom Hz** (своё число 30…165)
- ключи пишутся и в `system`, и в `secure` (HyperOS читает оба), после записи — проверка «применилось / не применилось»

**📡 Other**
- ИК-пульт: импорт `.ir` с Flipper Zero, пульты — квадратные плитки, «+» сверху
- тап по плитке открывает команды пульта, после импорта управление открывается само
- протоколы: NEC, NECext, NEC42, NEC42ext, Samsung32, SIRC/15/20, RC5, RC6, Kaseikyo, RCA + raw
- просмотр **build.prop** с поиском и копированием

**Root**
- стартовый экран: без root — кнопки «Повторить» и «Выход»
- доступ через KernelSU API (`prctl` + `supercall` ioctl) с жёсткой проверкой и откатом на `su`

## сборка и релиз

пуш в `main` → GitHub Actions собирает пакет и кидает в Releases файлом
`AnyHack-arm64-R<номер>.apk`.

## установка

```bash
gh release download -R internetov-coder/AnyHack --pattern "*.apk"
adb install -r AnyHack-arm64-R*.apk
```

## стек

Flutter (Material 3) + Kotlin (`ConsumerIrManager`, SAF-пикер) + root shell через `su`/KernelSU API.
