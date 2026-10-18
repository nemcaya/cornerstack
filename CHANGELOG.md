# Changelog

## 1.1.0 (2026-10-18)

- Settings window (menu bar icon › Settings…, or open the app again): card size, shortcuts, screenshot handling, copied images, full screen, sounds and open at login.
- Card size: Automatic fits the cards to the screen they are on; Small, Medium, Large or any width with the slider.
- Put back last card: brings back what you removed by accident.
- Keep on stack: click the pin in a card's top right corner. A kept card stays when you drop it into an app, new captures push the other cards out first, and it has no cross, so it can't be removed by accident.
- Copy Text: reads the text in a screenshot on your Mac.
- Copy Path, or ⌥-click a card: the file's path, quoted for a terminal.
- Quick Look: force click a card; the arrow keys step through the stack.
- ⌥⌘C copies the newest card from anywhere, and ⌥⌘T (was ⌃⌥T) hides or shows the stack. Change either one, or turn it off, in Settings.
- Lighter: while cards are showing and you work in other apps, Cornerstack no longer checks the pointer 30 times a second; it only reacts when the pointer moves. A new capture is decoded once, off the main thread, for both its card and its flight.
- Cards stay sharp at every size.

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
