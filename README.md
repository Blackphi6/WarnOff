# WarnOff

<video src="https://github.com/user-attachments/assets/eed20d7c-22d8-41c8-8fc7-196fbd6e195f" controls width="800" title="WarnOff demo"></video>

Menu bar tool for macOS that clears the Gatekeeper quarantine mark (`com.apple.quarantine`) from `.app` / `.dmg` / `.zip` files in a folder you choose (default: `/Applications`).

メニューバーだけで動く Mac 用の小さな道具です。選んだフォルダに入った `.app` / `.dmg` / `.zip` から、警告の印（隔離属性）を自動で消します。最初の対象は `/Applications` です。

**Use only on files you trust.** Removing quarantine also removes a safety check for unknown downloads.

**自分で入れたファイル向けです。** 見知らぬアプリの警告まで消すと、危ないソフトまで開いてしまうことがあります。

## Requirements

- macOS 14+
- Apple Silicon or Intel
- To build from source: Xcode Command Line Tools (`xcode-select --install`)

## Install (release zip)

1. Download `WarnOff-macOS.zip` from [Releases](https://github.com/Blackphi6/WarnOff/releases).
2. Unzip and move `WarnOff.app` to `/Applications`.
3. Open it (Control-click → Open if macOS blocks it the first time).
4. Click the shield icon in the menu bar.

## Build from source

```bash
git clone https://github.com/Blackphi6/WarnOff.git
cd WarnOff
make
make install
```

`make` builds a universal app and runs self-checks.  
`make install` copies to `/Applications/WarnOff.app` and launches it.

## Usage

1. Click the **shield** in the menu bar.
2. Default watch folder is `/Applications`.
3. Change folder with “Change watch folder…” / 「対象フォルダを変える…」.
4. Clear existing marks with “Clear warnings now” / 「今ある警告の印を消す」.
5. Optional: open at login.
6. Activity log: `~/Library/Logs/WarnOff.log`
7. Quit with “Quit WarnOff” / 「WarnOff を終了する」 (this exits the app; there is no separate “pause watching” item).

Incomplete downloads (`.download`, `.crdownload`, …) are skipped. Missing paths are ignored.

### One-shot CLI

```bash
./dist/WarnOff.app/Contents/MacOS/WarnOff --once /Applications
```

## Languages

UI follows the Mac language: English, Japanese, Simplified Chinese.

## License

MIT — see [LICENSE](LICENSE).
