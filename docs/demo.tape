# SeaShell README demo — regenerate with docs/demo/record.sh
#
# Shows the marquee path: list named Claude Code sessions, then
# `hey continue with myapp` to resume last night's conversation.
# Fixtures in docs/demo/bin/ stand in for the real CLI (no secrets, no network).

Output assets/demo.gif

Require bash
Require hey
Require seashell-sessions

Set Shell "bash"
Set FontSize 14
Set FontFamily "JetBrains Mono, DejaVu Sans Mono, monospace"
Set Width 780
Set Height 500
Set Padding 18
Set Framerate 12
Set PlaybackSpeed 1.0
Set TypingSpeed 60ms
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set WindowBarSize 36
Set Margin 10
Set MarginFill "#1e1e2e"
Set BorderRadius 8

Hide
Type "export PS1='\[\e[36m\]~/Github/myapp\[\e[0m\] \$ '"
Enter
Ctrl+L
Show

Sleep 350ms
Type "seashell-sessions"
Enter
Sleep 2.4s
Type "hey continue with myapp"
Enter
Sleep 8.5s
