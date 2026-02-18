
DOH for macOS
https://github.com/paulmillr/encrypted-dns

diff.sh - скрипт для проверки defaults изменений
https://github.com/yannbertrand/macos-defaults/blob/main/diff.sh

`brew bundle --verbose --file=./Brewfile`
Отваливается при failed адресах, которые заблокированны, поэтому росле делаем
`ALL_PROXY=socks://...: brew bundle --verbose --file=./Brewfile`

"All Applications". In the "Menu Title" field type "Lock Screen" and press your shortcut

В последних профилях была проблема на новой ОС
`security cms -D -i dns-base.mobileconfig -o plain.mobileconfig`

```xml
<key>PayloadScope</key>
<string>System</string>
```

```
xattr -dr com.apple.quarantine /Applications/LibreWolf.app
xattr -dr com.apple.quarantine ~/Downloads/v2rayN
```
