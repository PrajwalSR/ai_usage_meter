# Before making this public

What to do before open-sourcing AI Usage Meter. None of it blocks a **private**
GitHub backup; that only needs [the last section](#before-any-push-even-private).

```mermaid
flowchart LR
    P["Private backup"] --> D["Decide: license,<br/>logos"] --> T["Test from a<br/>clean clone"] --> R["Public"]
```

---

## 1. Decide

### License

With no license, nobody else may use the code.

| License | In simple words |
|---|---|
| **MIT** | Anyone can do anything, just keep your name. Most common for small apps. |
| **Apache 2.0** | Like MIT, plus protection around patents. |
| **GPL-3.0** | Anyone can use it, but a shared changed version must also be open source. |

GitHub can add one for you: **Add file → Create new file → name it `LICENSE` →
Choose a license template**.

### Logos

`assets/claude.svg` and `assets/openai.svg` come from Simple Icons (CC0), but the
logos are **trademarks**. See [assets/README.md](../assets/README.md).
- Keep the "not made by or connected to Anthropic or OpenAI" line in the README.
- If either company objects, swap in plain text labels.

### The website sign-ins

Claude's and ChatGPT's numbers come from claude.ai's and chatgpt.com's own usage
endpoints, read from inside sign-in windows the app owns. Before publishing,
decide:

- **Are you comfortable shipping an embedded sign-in?** Users should be told
  plainly whose page they are typing a password into. The README and SECURITY.md
  say so; keep that prominent.
- **Anthropic's and OpenAI's terms.** These endpoints are not published APIs.
  Using them for a personal read-only usage meter is the same thing several App
  Store apps do, but they are not documented, supported interfaces, and either
  company could object or change them.
- **Google sign-in doesn't work** inside embedded windows. Keep that in the README.

---

## 2. Set up the GitHub repository

- [ ] **Turn on private vulnerability reporting:** Settings → Code security →
      Private vulnerability reporting. SECURITY.md tells people to use it.
- [ ] **Add a build check:** a GitHub Actions workflow on a macOS runner that runs
      `./build-app.sh` and `./scripts/run-tests.sh`.
- [ ] Add a short description and topics (macos, menubar, claude, codex).

## 3. Clean up

- [ ] **Keep `assets/app-icon.svg`.** It's the editable source of the app icon.
- [ ] Consider a unique bundle id instead of `local.aiusagemeter`, like
      `io.github.prajwalsr.aiusagemeter`. Change it in `build-app.sh` and in the
      `defaults write` command in the README.

## 4. Test like a new user

- [ ] Clone into a new folder and follow the README exactly
- [ ] Before signing in to anything: no warnings in the panel, and `lsof` (see
      SECURITY.md) shows no connections
- [ ] Sign in to each site; both cards switch to "From claude.ai" / "From chatgpt.com"
- [ ] Without the ChatGPT sign-in, the ChatGPT card still works from Codex's logs
- [ ] Confirm macOS never shows a Keychain prompt
- [ ] Check that the screenshots still match the app (`./scripts/render-screenshots.sh`)

## 5. Optional: ready-made downloads

To share a `.app` that opens without warnings you need the Apple Developer Program
($99/year), a Developer ID signature with Hardened Runtime, and notarization. Not
needed if people build from source.

---

## Before any push, even private

```bash
# 1. Tests pass
./scripts/run-tests.sh

# 2. No personal info or tokens in the files
grep -rnIE "sk-ant|Bearer [A-Za-z0-9]|/Users/[a-z]|@gmail" \
  --exclude-dir=build --exclude-dir=.build --exclude-dir=.git --exclude=SECURITY.md .

# 3. See exactly what would be committed
git add -A
git status
```

In `git status`, make sure **none** of these appear:
- `build/` or `.build/`
- any `.sqlite`, `.db` or `Cache.db` file
- any `.jsonl` file (session logs)
- `claude.json`, `claude-web.json`, `codex-web.json`, `*-raw.json`, `auth.json`

They're all in `.gitignore`, but check anyway before you commit.
