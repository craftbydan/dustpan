# Privacy

Dustpan runs only on your Mac and collects nothing.

- No analytics, no crash reporting, no accounts.
- Scan results stay in memory. Dustpan writes two files of its own:
  - its history database in `~/Library/Application Support/Dustpan/` (what was moved to the Trash, and what you asked it to ignore);
  - a small summary of Homebrew's app list in `~/Library/Caches/app.dustpan.Dustpan/homebrew-casks-v3.json` (about 1 MB), only after you open the Updates tab, so the list isn't downloaded again within 24 hours.
- Dustpan looks at file names, sizes and dates. It never reads the contents of your documents, except to hash a file's contents when you ask it to find duplicates.
- Network: none, except the optional "Updates" tab in Apps, which runs only when you open it (or press Check again; at most once an hour on its own). It asks whether newer versions of your apps exist:
  - the Mac App Store (`itunes.apple.com/lookup`): the bundle IDs of your App Store apps and your region code (e.g. "us"), so the right store answers;
  - apps' own update feeds: the HTTPS `SUFeedURL` in each app's Info.plist (plain-http feeds are never read). These are each developer's own servers, which see your IP address, as they do when the app checks for updates itself;
  - Homebrew (`formulae.brew.sh/api/cask.json`), downloaded at most once a day and only if some app needs it.

  It sends app identifiers, never your files. No cookies are kept. Nothing is downloaded or installed apart from those lists.
