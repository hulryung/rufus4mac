# App languages

The app supports English, Korean, Japanese and Spanish. On first launch it uses **System default**:
it follows macOS's preferred-language order, chooses the first supported language, and falls back to
English if none are supported. Region variants such as `ko-KR`, `ja-JP`, and `es-MX` resolve to their
base language.

Open the globe button in the main window or press **Command–comma** to change the app language.
The choice is applied immediately and saved under the `appLanguage` UserDefaults key. Select
**System default** to restore automatic selection. Language changes do not rebuild the main view's
identity, reset image/USB selections, or restart a writer.

## UI language is separate from installation language

This preference changes rufus4mac's interface only. Windows media still uses its own installation
language, and the existing “Use this Mac's region & language” option still derives regional settings
from macOS, not the app's language override. Catalog model names, package descriptions, filenames,
paths and diagnostic output from external tools stay in their original form. Standard macOS dialogs
and menu items may follow the operating system's own language rather than an in-app override.

## Resources and configuration

- `Sources/Localization/Resources/languages.json`: languages available in the settings picker, with
  stable IDs and native display names.
- `Sources/Localization/Resources/en.json`: English messages and fallback translations.
- `ko.json`, `ja.json`, `es.json`: translated messages keyed by the English source template.
- `App/Resources/<language>.lproj/InfoPlist.strings`: localized removable-volume permission text.
- `App/AppLanguage.swift`: persisted preference and the language settings sheet.

Example manifest entry:

```json
{ "id": "ko", "nativeName": "한국어" }
```

Messages use numbered placeholders. Translators may reorder them, but must preserve every
placeholder exactly:

```json
{
  "{0} of {1} models": "모델 {1}개 중 {0}개"
}
```

The Swift `Message` interpolation type keeps user data out of the lookup key. Placeholder expansion
runs once, so a filename containing `%@` or `{1}` is shown literally. Do not build sentences by
concatenating translated fragments; translate the full message so each language can choose its
own word order. Display model names and paths as data, not as translation keys.

## Add another language

1. Copy `en.json` to `<language-id>.json` in the same directory and translate its values.
2. Add the language's ID and native name to `languages.json`. The picker reads this manifest;
   there is no language-specific Swift view to edit.
3. Add the corresponding `InfoPlist.strings` file for the native permission prompt.
4. Run `xcodegen generate`, `swift test --filter LocalizationTests`, and an app build.
5. Inspect all three tasks, confirmations, driver sheets and language settings at minimum window
   width. Verify long names, counts and errors, then restart and confirm the saved preference.

The tests check language negotiation, fallback, complete translation-key coverage, matching
placeholder sets, argument reordering and preservation of destructive-confirmation details.
