# Changelog

## 1.2.1 (2026-11-15)

- Copy Text and Hide Secrets no longer return letters from the wrong alphabet. Apple's text recognition sometimes reads monospaced text, like a key in a terminal, as Cyrillic or Greek letters that look the same (a Cyrillic О for an O). A copied key then didn't work, and Hide Secrets could miss it. Those letters are now put back in words that mix them with Latin letters, and a Ø, × or ı in the middle of a key becomes 0, x or i. A word written only in Cyrillic or Greek stays as it is. If one of them is among your Mac's languages, a word only changes when the alphabets are mixed inside one run of letters, so "НАТО/NATO" stays too. Text recognition can still take an O for a 0 or an l for a 1, so check a copied key.
- Hide Secrets finds more: values after any name that ends in key, token or secret, like ENCRYPTION_KEY or "accessToken", and card numbers in which a 1 was read as an l. A QR code or barcode that holds a secret, like the setup code of an authenticator app or a Wi-Fi password, is covered whole. On a photo that is stored turned on its side the bars now land on the text.
- The 30 days a capture stays in Cornerstack's folder count from when it left the stack. Before, they counted from when it was taken, so a card that had been on the stack for a month went to the Trash soon after it left.
- Handle screenshots puts your screenshot folder back when it is in iCloud Drive, Dropbox, OneDrive or Google Drive. Before, quitting left your screenshots going to the Desktop.
- With Handle screenshots on, captures taken while Cornerstack was not running, after a force quit or a power cut, land on the stack the next time it opens: the newest five, and the rest are in History.
- Pick another folder in the Options of ⌘⇧5 and Cornerstack follows it the next time you switch apps or Spaces. Before, it needed a restart. With Handle screenshots on, Cornerstack's own folder is set again the next time it starts.
- ⌘W closes Settings and History, and ⌘, ⌘Y and ⌘Q work while one of them is in front. When the last window closes, the app you were in is active again.
- Keys over a card: the key you press stays taken for as long as you hold it, up to half a minute, so a held ⌫ doesn't go on to delete text in the app behind. P pauses the keys like every other key, and they let go when you switch apps.
- When an image can't be read, the card says so instead of "No secrets found". When its file is gone, the card leaves instead of saying "Copied". Save to Desktop keeps the capture in History. A capture that another tool is still writing gets its finished image.
- Lighter: Copy at 1x no longer holds up the stack while it scales, Copy Text and Hide Secrets go ahead of captures still waiting to be read, and History lets go of its images when you close it.

## 1.2.0 (2026-11-05)

- Tuck away: left alone for 10 seconds, the stack slides off the edge of the screen into a small tab just above the corner that shows how many cards wait there. Point at the tab, take a screenshot or press ⌥⌘T to bring it back. Nothing leaves the stack. Choose 5, 10 or 30 seconds, or never, in Settings.
- Keys over a card: point at a card and press C to copy it, 1 to copy it at 1x, T to copy its text, S to share it, R to hide its secrets, L to open its QR code, P to keep it, Space for Quick Look or ⌫ to remove it. They pause after a key or a click until the pointer moves again, and need no Accessibility permission. Turn them off in Settings.
- QR codes: a screenshot with a QR code or barcode gets a button that opens its link or copies what it says. Copy Text adds what the code says at the end.
- Hide Secrets: a copy of the screenshot with API keys, tokens, passwords, email addresses, card numbers and IBANs painted over lands on the stack. The original stays as it is.
- Share: the system's share menu (AirDrop, Messages, Mail and more) in a card's menu.
- Copy at 1x: Shift-click a card, press 1 over it or choose Copy at 1x, and a Retina screenshot is copied at the size it had on screen, half as wide and high, for chats and issues. The file stays as it is.
- History: menu bar icon › History… shows every capture of the last 30 days that was on the stack, grouped by day. Drag one into any app, double click it to put it back on the stack, or right click for Copy, Copy at 1x, Copy Text, Quick Look, Show in Finder and Move to Trash.
- Copy Text keeps code, links and keys exactly as they are on screen, and is ready at once: each capture is read in the background when it lands.

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
