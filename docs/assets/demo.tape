# Hero GIF for the README. Regenerate with: vhs docs/assets/demo.tape
# Needs vhs, ttyd and ffmpeg, and a machine already set up with agbox.

Output docs/assets/demo.gif

Set Shell bash
Set FontFamily "JetBrains Mono"
Set FontSize 15
Set LineHeight 1.15
Set Width 820
Set Height 1200
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 60ms
Set WindowBar Colorful

# Tidy prompt; skip the SSH check (this box uses Tailscale SSH) and hide the tailnet name.
Hide
Type `export PS1='\[\e[32m\]antomanc@home-server\[\e[0m\]:\[\e[34m\]~\[\e[0m\]$ '`
Enter
Type `agbox() { "$PWD/bin/agbox" "$@" --skip ssh | sed -E 's/\.[a-z0-9-]+\.ts\.net/.tailnet.ts.net/'; }`
Enter
Type "clear"
Enter
Show

Sleep 800ms
Type "agbox doctor"
Sleep 400ms
Enter
Sleep 5s
