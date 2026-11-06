# Jailbreak Your Kindle Paperwhite and Install Pixel KOReader

Nov 6, 2026 · written for a Kindle Paperwhite 12th generation on firmware 5.20.1.0.2

## Before you start

Your Kindle can be jailbroken today with **Véra**, a jailbreak that runs from the Kindle's own web browser. It takes about 30 minutes, plus 15 for KOReader.

|  | Your Kindle |
| --- | --- |
| Model | Kindle Paperwhite 12th generation (2024), called **PW6** in jailbreak guides |
| Firmware | 5.20.1.0.2 |
| Jailbreak to use | **Véra** (supports PW6 on firmware 5.17.1 to 5.20.2) |
| Kindle package to install afterwards | `koreader-pixel-kindlehf.zip` |

**The one rule: do not update your Kindle until the jailbreak is done.** If Amazon installs anything newer than 5.20.2, Véra may stop working and there may be no way back. Step 1 blocks updates.

**What you need:**

- The Kindle, charged above 50%
- Wi-Fi the Kindle can join (Véra needs it until the last step)
- Your Mac and a USB-C cable (for copying files)
- About 45 minutes without interruptions

**What changes and what doesn't:**

- Your Amazon books, store and normal reading app keep working exactly as before.
- KOReader is added as a separate app with its own icon on the Home screen.
- Everything here can be undone (see the last section).

**Check before you begin:** open [kindlemodding.org/jailbreak-wizard.html](https://kindlemodding.org/jailbreak-wizard.html) on your Mac, enter your serial number and firmware, and confirm it says **Véra**. Jailbreak support changes often; if it says anything else, stop and ask.

## Step 1: Stop automatic updates

Fill the Kindle's storage almost to the brim, so it has no room to download an Amazon update while you work. This is the step that protects the jailbreak.

**Your Kindle uses MTP, not a USB drive.** On a Mac it won't show up in Finder. You need a free app to copy files: [OpenMTP](https://openmtp.ganeshrvel.com).

1. **Install OpenMTP** on your Mac and open it.
2. **Turn on Airplane Mode** on the Kindle: swipe down from the top, tap **Airplane Mode**.
3. **Plug the Kindle into the Mac** with the USB-C cable. In OpenMTP, the right-hand side shows the Kindle's files. If it asks to allow access, say yes on the Kindle.
4. **Find your Kindle's storage size:** on the Kindle, **⋮ (3 dots) > Settings > Device Options > Device Info**. It's usually 16 GB (or 32 GB for Signature Edition).
5. **Download the matching filler file** on your Mac from [Kindle-Filler-Disk / MTP](https://github.com/Crosunt223/Kindle-Filler-Disk/tree/main/MTP): `fill_16gb.zip` for 16 GB, `fill_32gb.zip` for 32 GB.
6. **Unzip it** (double-click). It becomes a folder of large blank files, about the size of your Kindle. Make sure your Mac has that much free space.
7. **Copy the files to the Kindle** with OpenMTP: drag them into the Kindle's top folder (next to `documents`, not inside it). Stop when the Kindle is full; it's fine if the last file won't fit. This can take 10–20 minutes.
8. **Check the free space** on the Kindle: **⋮ > Settings > Device Options > Device Info** (or **Storage Management**). You want **about 50–90 MB free**. If there's more, copy another file; if it's too tight to work, delete one.
9. **Delete any update files** in the Kindle's top folder if you see them: anything named `update.bin`, `update-something.bin`, or `update.bin.tmp.partial`.
10. **Unplug the Kindle** and turn Airplane Mode **off**. Connect to Wi-Fi. (Véra needs Wi-Fi; the full storage stops the update.)

## Step 2: Jailbreak with Véra

Véra uses two special books: you set a font theme in one, then open the other, and the Kindle unlocks itself. Keep Wi-Fi **on** the whole time.

1. **Check your firmware.** **⋮ > Settings > Device Options > Device Info.** It should say `5.20.1.0.2`. Close the menu with the **X**.
2. **Open the browser.** **⋮ > Web Browser.** Type this address and go:
   - `https://kindlemodding.org/vera`
3. **Pick your device and firmware.** Choose your Kindle if asked, then your firmware from the list.
   - **Make sure 5.20.1 (or 5.20.1.0.2) is in the list.** If it isn't, **stop here** and ask. Don't pick a different version.
4. **Download both books.** Two links appear. Wait 2–3 seconds, then:
   - Tap **Font Calibration** and confirm with **OK**.
   - Tap the **Véra** book for your device and confirm with **OK**.
   - Close the browser with the **X** at the top right. Leave Wi-Fi on.
5. **Open the Font Calibration book** from your library. Tap the top of the page, then tap **Aa**.
6. **Set the font.** In the **Font** tab at the bottom:
   - Font family: **Bookerly**
   - Bold: **0**
   - Size: the **biggest** setting
7. **Set line spacing.** Open **Layout** at the top and pick the **middle** spacing. (If you only see a **Spacing** option, set Line Spacing to **2**, then tap the arrow at the top left.)
8. **Save it as a theme.** Open **Themes** at the top, tap **Save current settings**, then **Save** again.
9. **Leave the book.** Tap the top-left corner of the screen **3 times** to get back to Home or Library.
10. **Open the Véra book.** Wait a few seconds. Text runs from the top left, then a **RESTARTING GUI** screen appears.
11. **Done when the Kindle restarts its screens.** Your Kindle is now jailbroken. Ignore any "application error" pop-ups; they're harmless.
12. **Clean up.** Delete the **Véra** and **Font Calibration** books from your library.

**If nothing happens** when you open the Véra book, redo steps 5–9 exactly (font, spacing, theme) and try again.

## Step 3: After the jailbreak

A modern jailbreak blocks Amazon updates by itself and installs **KPM**, a small app store you use by typing commands into the Kindle's search bar. The old KUAL launcher is no longer needed.

1. **Restart the Kindle** if it didn't restart on its own: hold the power button, choose **Restart**.
2. **Remove the filler files.** Plug into the Mac, open **OpenMTP**, and delete the filler files you copied in Step 1 (the big blank files in the Kindle's top folder).
3. **Remove any update files** in the top folder: `update.bin`, `update-something.bin`, `update.bin.tmp.partial`. If there are none, good: nothing downloaded.
4. **Unplug** and make sure Wi-Fi is on.
5. **Refresh the app list.** Tap the **search bar** on the Home screen, type exactly this and press Enter:
   - `;kpm update`
   - Some text flashes at the top, then you're back on Home.
6. **Install Jobman** (the jailbreak's control panel): search for
   - `;kpm install jobman`
   - A new icon appears on Home. It's where you turn updates back on later, if you ever undo everything.

**Leave updates blocked.** Never tap **Update Your Kindle**, and don't copy Amazon `.bin` files onto it. A forced update is the one thing that can undo the jailbreak.

## Step 4: Install Pixel KOReader

First install the official KOReader with KPM (that gives you its Home-screen icon), then replace its folder with the Pixel version. The Pixel package is a complete KOReader of a matched version, so swapping the whole folder is safe.

1. **Install KOReader.** On the Kindle, search for:
   - `;kpm install koreader`
   - A **KOReader** icon appears on Home (it can take a moment). Open it once to check it starts, then close it (**☰ menu > Exit**).
2. **Download the Pixel package** on your Mac: [Releases → koreader-pixel-kindlehf.zip](https://github.com/AniketShahane/koreader-pixel/releases/tag/v0.1.0). Unzip it. You get a `koreader` folder (and an `extensions` folder you can ignore).
3. **Plug the Kindle in** and open **OpenMTP**.
4. **Rename the old folder** on the Kindle: right-click `koreader` > Rename > `koreader-old`. (Your safety copy.)
5. **Copy the new `koreader` folder** from your Mac into the Kindle's top folder. It's about 90 MB of small files; give it a few minutes.
6. **Unplug** and tap the **KOReader** icon. You should see **▶ LIBRARY** and your covers.
   - If it doesn't open: plug back in, delete the new `koreader`, rename `koreader-old` back to `koreader`, and tell me.
7. **Add your Claude key.** On your Mac, make a plain text file named `claude_api_key.txt` containing only the key (starts with `sk-ant-`). Copy it into the Kindle's `koreader` folder.
8. **Add a dictionary** (for single words): in KOReader, tap the top of a page > **gear tab > Dictionary settings > Download dictionaries** > pick **WordNet (English)**. Needs Wi-Fi.
9. **Add books.** Copy DRM-free EPUBs into the Kindle's `documents` folder with OpenMTP. Books bought from Amazon are locked and won't open in KOReader.
10. **Delete `koreader-old`** once everything works.

**Using it:** long-press a word for the dictionary (with **ASK CLAUDE**); select several words and tap **EXPLAIN WITH CLAUDE**; tap the page-number bar for **OPTIONS** (font, size, spacing).

## If something goes wrong

None of these break the Kindle; most are fixed with a restart.

| What you see | What to do |
| --- | --- |
| Stuck on any screen | Hold the power button about 15 seconds until it restarts |
| "Application error" pop-ups | Ignore them; they're harmless |
| Nothing happens when you open the Véra book | Redo Step 2, items 5–9 (font, spacing, theme) exactly, then open it again |
| "If you have bought this item from Amazon…" | Delete both books, restart, start Step 2 again |
| Your firmware isn't in Véra's list | Stop. Don't pick another version. Ask (below) |
| The Kindle shows a new firmware version | Stop. Check the [Jailbreak Wizard](https://kindlemodding.org/jailbreak-wizard.html) again before going on |
| Pixel KOReader won't open | Put `koreader-old` back as `koreader` (Step 4, item 6) |
| Mac can't see the Kindle | Use OpenMTP, not Finder; unlock the Kindle and allow access on its screen |

**Help:** the [KindleModding Discord](https://discord.kindlemodding.org/) and [r/kindlejailbreak](https://www.reddit.com/r/kindlejailbreak/) are where the Véra authors answer questions.

## How to undo it later

You can go back to a normal Kindle in about 20 minutes. Most people never need to: KOReader sits beside the normal reader, and you can just stop opening it.

**Remove only KOReader:** search `;kpm uninstall koreader`, then delete the `koreader` folder with OpenMTP.

**Remove the jailbreak completely** (for example before selling the Kindle or sending it for repair):

1. **Turn Amazon updates back on.** Open **Jobman** and choose the option to **enable updates** (named "Enable OTA Updates" in the guide).
2. **Install an official Amazon firmware file.**
   - Find your model (**Paperwhite 12th gen**) on [FTVDB](https://ftvdb.com/) or Amazon's [Kindle Software Updates](https://www.amazon.com/gp/help/customer/display.html?nodeId=GKMQC26VQQMM8XSW) page and download its `.bin` file.
   - Copy the `.bin` into the Kindle's top folder with OpenMTP (next to `documents`, not inside).
   - On the Kindle: **⋮ > Settings > Device Options > Update Your Kindle**.
3. **Factory reset:** **⋮ > Settings > Device Options > Reset**.

**The catch:** once you undo it, Amazon controls updates again. If a newer update closes the Véra hole, you may not be able to jailbreak again.

## Sources

- [KindleModding: Jailbreaking overview](https://kindlemodding.org/jailbreaking/)
- [KindleModding: Véra](https://kindlemodding.org/jailbreaking/Vera/)
- [KindleModding: supported models and firmware (jailbreaks.json, updated 4 Nov 2026)](https://github.com/KindleModding/kindlemodding.github.io/blob/main/static/jailbreaks.json)
- [KindleModding: Prevent automatic updates](https://kindlemodding.org/jailbreaking/prevent-auto-update/)
- [Kindle-Filler-Disk (MTP filler files)](https://github.com/Crosunt223/Kindle-Filler-Disk)
- [KindleModding: What's next](https://kindlemodding.org/jailbreaking/whats-next/index.html)
- [KindleModding: Jailbreaking Manager (Jobman)](https://kindlemodding.org/jailbreaking/whats-next/jailbreaking-manager/)
- [KindleModding: Getting KOReader](https://kindlemodding.org/jailbreaking/whats-next/getting-koreader/)
- [KindleModding: Unjailbreaking your Kindle](https://kindlemodding.org/jailbreaking/faq/unjailbreaking.html)
- [The eBook Reader: Kindle 5.20.1 and Véra](https://blog.the-ebook-reader.com/2026/10/06/kindle-software-update-5-20-1-released-but-its-not-the-latest-version/)
