
DOH for macOS
https://github.com/paulmillr/encrypted-dns

diff.sh - script for checking defaults changes
https://github.com/yannbertrand/macos-defaults/blob/main/diff.sh

`brew bundle --verbose --file=./Brewfile`

If failed url, do with proxy variable
`ALL_PROXY=socks://...: brew bundle --verbose --file=./Brewfile`

"All Applications". In the "Menu Title" field type "Lock Screen" and press your shortcut

Last profiles had issue on new macos, solution:
`security cms -D -i dns-base.mobileconfig -o plain.mobileconfig`

```xml
<key>PayloadScope</key>
<string>System</string>
```

```
xattr -dr com.apple.quarantine /Applications/LibreWolf.app
xattr -dr com.apple.quarantine ~/Downloads/v2rayN
```
