# RuSwitcher

<p align="center">
  <img src="icon.png" width="128" alt="RuSwitcher icon">
</p>

<p align="center">
  A menu-bar utility for manually converting recently typed text between two keyboard layouts on macOS.
</p>

<p align="center">
  <a href="#english">English</a> · <a href="#русский">Русский</a>
</p>

## English

RuSwitcher converts the last typed word or key sequence after you press a configured trigger. For example, if you type `ghbdtn` in an English layout and press the trigger, the app can replace it with `привет` and switch to the other configured layout.

RuSwitcher does **not** detect or correct wrong-layout words automatically. It acts only when you press the trigger.

### What the current code does

- Monitors keyboard events while RuSwitcher is enabled.
- Keeps key codes for the current sequence in memory. After a space, it can also convert the preceding sequence and preserve the spaces.
- Uses the macOS `UCKeyTranslate` API to map the same physical keys between two configured layouts.
- Sends Backspace events and inserts the converted Unicode text directly. It does not use the system clipboard.
- Allows a second trigger press to reverse the last conversion while the short-lived undo state is still available.
- Lets you select any installed layout from the menu-bar menu.
- Optionally remembers the active layout separately for each application.
- Optionally shows a layout flag near the text cursor, plays a sound after a layout change, uses a monochrome menu-bar badge, and starts at login.
- Provides interface translations for 16 languages.

The conversion trigger can be Option, Command, Control, Shift or Caps Lock; the left/right side and single/double tap can be configured. The available two-key triggers are Command+Shift, Control+Shift, Command+Option and Control+Option.

### Limits

- Conversion is manual; there is no dictionary-based or automatic correction.
- Only two layouts are used for conversion at a time. They can be selected in Settings; if they are not selected, the app tries to choose an English layout and another installed layout.
- Conversion requires both layouts to expose Unicode keyboard-layout data through macOS. Input methods that do not expose that data cannot be converted.
- The app relies on Accessibility and synthesized keyboard events. Conversion may not work in applications or fields that reject those events or do not expose a usable focused text element.
- The optional cursor flag appears only where Accessibility provides the text-cursor bounds.

### Privacy and local state

- The current source contains no networking, updater or telemetry code.
- Typed text is not written to disk. Preferences such as selected layouts and enabled options are stored in `UserDefaults`.
- The current key-code buffer is cleared after 15 seconds without a new key event, and also when monitoring stops or the input context becomes unsafe or changes.
- Text retained for reversing the last conversion is cleared after 5 seconds.
- Input is rejected when macOS Secure Event Input is active, when Accessibility identifies protected content, and in a small built-in blocklist of password managers and Apple remote-session applications.
- Older RuSwitcher log files and settings from the removed dictionary-based conversion feature are deleted on launch.

These protections describe the current implementation; they are not a guarantee against a compromised operating system or a custom password field that macOS does not identify as protected.

### Requirements and permissions

- macOS 13 or later.
- Accessibility permission, used to verify the focused element and insert converted text safely.
- Input Monitoring permission, used to observe keyboard events.

RuSwitcher includes a permission wizard, but the user must grant the permissions in macOS System Settings.

### Build from source

```bash
git clone https://github.com/win-win-code/RuSwitcher-offline-.git
cd RuSwitcher-offline-
bash build_app.sh
cp -R RuSwitcher.app /Applications/
```

The project uses Swift 6, AppKit, Carbon, CoreGraphics and ServiceManagement. A compatible Xcode Command Line Tools installation is required. Each build made after a source change automatically increments the patch version and build number. The build script signs the local app with an available code-signing identity, or ad hoc if none is available.

### License

[MIT](LICENSE)

---

## Русский

RuSwitcher конвертирует последнее набранное слово или последовательность клавиш после нажатия настроенного триггера. Например, если набрать `ghbdtn` в английской раскладке и нажать триггер, программа может заменить текст на `привет` и переключить раскладку на вторую настроенную.

RuSwitcher **не определяет и не исправляет ошибочную раскладку автоматически**. Конвертация запускается только по нажатию триггера.

### Что делает текущая версия кода

- Отслеживает события клавиатуры, пока RuSwitcher включён.
- Хранит в памяти коды клавиш текущей последовательности. После пробела также может конвертировать предыдущую последовательность, сохранив пробелы.
- Сопоставляет физические клавиши двух настроенных раскладок через системный API `UCKeyTranslate`.
- Отправляет Backspace и вставляет сконвертированный Unicode-текст напрямую. Системный буфер обмена не используется.
- Позволяет повторным нажатием триггера отменить последнюю конвертацию, пока доступно кратковременное состояние отмены.
- Позволяет выбрать любую установленную раскладку из меню в строке меню.
- Опционально запоминает активную раскладку отдельно для каждого приложения.
- Опционально показывает флаг раскладки у текстового курсора, воспроизводит звук после смены раскладки, использует монохромную иконку в строке меню и запускается при входе в систему.
- Содержит переводы интерфейса на 16 языков.

Триггером может быть Option, Command, Control, Shift или Caps Lock; настраиваются левая/правая сторона и одиночное/двойное нажатие. Доступные комбинации из двух клавиш: Command+Shift, Control+Shift, Command+Option и Control+Option.

### Ограничения

- Конвертация только ручная: словарного определения и автоматического исправления нет.
- Для конвертации одновременно используются две раскладки. Их можно выбрать в Настройках; если они не выбраны, программа пытается найти английскую и ещё одну установленную раскладку.
- Обе раскладки должны предоставлять macOS данные Unicode-раскладки. Методы ввода, которые не предоставляют эти данные, сконвертировать нельзя.
- Работа зависит от Accessibility и синтезированных событий клавиатуры. Конвертация может не работать в приложениях или полях, которые отклоняют такие события либо не предоставляют доступный сфокусированный текстовый элемент.
- Опциональный флаг у курсора появляется только там, где Accessibility возвращает координаты текстового курсора.

### Конфиденциальность и локальные данные

- В текущем исходном коде нет сетевых запросов, обновлятора и телеметрии.
- Набранный текст не записывается на диск. В `UserDefaults` сохраняются только настройки, например выбранные раскладки и включённые опции.
- Текущий буфер кодов клавиш очищается через 15 секунд без новых нажатий, а также при остановке мониторинга и при смене или небезопасном состоянии контекста ввода.
- Текст для отмены последней конвертации очищается через 5 секунд.
- Ввод отбрасывается, если активен macOS Secure Event Input, Accessibility помечает содержимое как защищённое либо активно приложение из небольшого встроенного списка менеджеров паролей и приложений удалённого доступа Apple.
- При запуске удаляются старые логи RuSwitcher и настройки удалённой словарной конвертации.

Это описание соответствует текущей реализации, но не является гарантией защиты от скомпрометированной операционной системы или нестандартного поля пароля, которое macOS не распознаёт как защищённое.

### Требования и разрешения

- macOS 13 или новее.
- «Универсальный доступ» (Accessibility) — для проверки сфокусированного элемента и безопасной вставки сконвертированного текста.
- «Мониторинг ввода» (Input Monitoring) — для отслеживания событий клавиатуры.

В RuSwitcher есть мастер разрешений, но разрешения пользователь выдаёт самостоятельно в Системных настройках macOS.

### Сборка из исходников

```bash
git clone https://github.com/win-win-code/RuSwitcher-offline-.git
cd RuSwitcher-offline-
bash build_app.sh
cp -R RuSwitcher.app /Applications/
```

Проект использует Swift 6, AppKit, Carbon, CoreGraphics и ServiceManagement. Нужна совместимая версия Xcode Command Line Tools. Каждая сборка после изменения исходников автоматически повышает patch-версию и номер сборки. Скрипт сборки подписывает локальное приложение доступным сертификатом для подписи кода, а при его отсутствии использует ad-hoc подпись.

### Лицензия

[MIT](LICENSE)
