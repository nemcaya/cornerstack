# Changelog

## 1.0.2 (2026-10-17)

- New home: github.com/nemcaya/cornerstack. The app ID is now `io.github.nemcaya.cornerstack`, so this version starts with fresh settings. Quit the previous version from its menu bar icon first, so it puts your screenshot settings back.

## 1.0.1 (2026-10-17)

- The cross only takes a capture off the stack; its file stays. Before, it moved captures in Cornerstack's own folder straight to the Trash, so *Open screenshots folder* could look empty.
- Captures in Cornerstack's folder stay there for 30 days after they leave the stack, then move to the Trash.
- Showing an empty stack shows its hint for a moment, then hides it again by itself.

## 1.0.0 (2026-10-17)

First release, reworked from [Tendedero](https://github.com/alejandrobujan/tendedero)
by Alejandro Buján.

- Screenshots and screen recordings stack in the bottom right corner, newest nearest the corner, up to five.
- The stack stays until you use or discard each capture. Nothing times out.
- New captures fly in from where you took them.
- Dragging a capture into an app removes it from the stack; the file stays on disk.
- Shows over full screen apps and stays out of new screenshots.
- Optional: take over the screenshot settings so captures skip the Desktop. Your settings come back when you quit, and any you change in the meantime are kept.
- Optional: add images you copy to the stack.
