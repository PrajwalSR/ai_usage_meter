# Assets

| File | What it is | Source |
|---|---|---|
| `app-icon.svg` | **Source artwork** for the app icon (firefly). Edit this one. | Made for this project |
| `AppIcon.iconset/`, `AppIcon.icns` | App icon at every size macOS needs | Generated from `app-icon.svg` |
| `firefly.png` | 1024 px render of the app icon | Generated from `app-icon.svg` |
| `matchstick-concept.svg` | An alternative icon idea, not used by the app | Made for this project |
| `claude.svg` | Claude logo, used in the menu bar | [Simple Icons](https://simpleicons.org) (CC0) |
| `openai.svg` | OpenAI logo, used in the menu bar | [Simple Icons](https://simpleicons.org) (CC0) |

## Rebuilding the app icon

After editing `app-icon.svg`:

```bash
./scripts/make-app-icon.sh              # updates AppIcon.iconset and AppIcon.icns here
./scripts/make-app-icon.sh build/icon   # or preview it somewhere else first
```

It renders the SVG at every size with macOS's built-in SVG support
(`tools/svg2png`) and packs them with `iconutil`. No other tools are needed.

## About the logos

Simple Icons releases its SVG files under CC0, so the *files* are free to use. The
**logos themselves are trademarks**: Claude and Anthropic belong to Anthropic;
OpenAI and ChatGPT belong to OpenAI. They appear here only to show which service a
number belongs to. This project isn't made by, or connected to, either company.
Don't use these logos as this app's own icon or branding.
