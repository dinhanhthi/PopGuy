<div align="center">

<img src="assets/logo_nobg.png" alt="PopGuy" width="140" />

# PopGuy

Select text in any app — a floating toolbar pops up so you can **improve**, **translate**,
or run a **custom AI action** on it. Think PopClip, with a configurable AI backend.

**[⬇ Download for macOS](https://github.com/dinhanhthi/PopGuy/releases/latest)**
&nbsp;·&nbsp; **[▶ Watch the demo](https://vimeo.com/1209095226)**
&nbsp;·&nbsp; macOS 13+ &nbsp;·&nbsp; signed &amp; notarized

</div>

## Features

- **Improve** — rewrite selected text with an AI model; shows an inline diff before you apply it
- **Translate** — translate selected text to your target language
- **Dictionary** — look up definitions for the selected word
- **Custom AI actions** — define your own actions with a system prompt
- **Action library** — install ready-made actions from a built-in catalog
- **Plugins & extensions** — extend PopGuy with your own plugin actions
- **PopClip extensions** — import many PopClip extensions (partial support)
- **Multiple providers** — OpenAI, Anthropic (Claude), Ollama / LM Studio (local), DeepL, Google Translate
- **Global hotkeys** — trigger any action from the keyboard
- **Cmd+C+C chord** — double-tap Cmd+C to Improve the current selection
- **Non-destructive** — your original text is never changed until you accept the result
- **Menu-bar app** — no Dock icon; lives in the menu bar
- **OCR** — capture text from any screen region

## Install

- **Download the app:** grab the latest signed &amp; notarized build from the
  [Releases page](https://github.com/dinhanhthi/PopGuy/releases/latest). It auto-updates
  itself after that.
- **Or build from source:** see below.

☝️ PopGuy needs **Accessibility** permission to read selected text and detect the `Cmd+C+C`
chord — grant it at **System Settings → Privacy &amp; Security → Accessibility** (the app
prompts you on first launch). API keys are stored in the system **Keychain**, never in
plaintext.

## Requirements

- macOS 13.0 or later
- Xcode 26.x (only to build from source)

## Build from source

```sh
git clone https://github.com/dinhanhthi/PopGuy.git
cd PopGuy
open PopGuy.xcodeproj      # press ▶ to run
```

Headless build / test:

```sh
xcodebuild build -scheme PopGuy -destination 'platform=macOS'
xcodebuild test  -scheme PopGuy -destination 'platform=macOS'
```

Then grant **Accessibility** (above) and add your provider API keys in **PopGuy → Settings**.

### Keep the Accessibility grant across rebuilds

macOS ties the Accessibility grant to the app's **code signature**. With Xcode's default
*Sign to Run Locally*, the signature changes every rebuild and the grant is revoked each
time. To make it stick, sign with a stable local certificate:

1. **Keychain Access → Certificate Assistant → Create a Certificate**.
2. Name it `PopGuy Dev`, type **Self Signed Root**, usage **Code Signing**.
3. In Xcode → **Signing &amp; Capabilities**, set the signing certificate to **PopGuy Dev**
   (not *Sign to Run Locally*).

This is a local development cert only — **not** a Developer ID, and no Apple Developer
Program membership is required.

## Contributing

Contributions are welcome — open an issue to discuss a change, or send a pull request.
See **[CONTRIBUTING.md](CONTRIBUTING.md)** for guidelines.

## License

PopGuy is open source under the
[GNU Affero General Public License v3.0](https://www.gnu.org/licenses/agpl-3.0.html).
You may use, modify, and distribute it under its terms. See [LICENSE](LICENSE) for
the full license text.
